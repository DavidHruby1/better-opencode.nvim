local M = {}

M.permissions = {
  { permission = "*", pattern = "*", action = "deny" },
  { permission = "read", pattern = "*", action = "allow" },
  { permission = "read", pattern = "*.env", action = "deny" },
  { permission = "read", pattern = "*.env.*", action = "deny" },
  { permission = "read", pattern = "*.env.example", action = "allow" },
  { permission = "glob", pattern = "*", action = "allow" },
  { permission = "grep", pattern = "*", action = "allow" },
  { permission = "lsp", pattern = "*", action = "allow" },
  { permission = "skill", pattern = "*", action = "allow" },
  { permission = "question", pattern = "*", action = "allow" },
  { permission = "StructuredOutput", pattern = "*", action = "allow" },
  { permission = "webfetch", pattern = "*", action = "ask" },
  { permission = "websearch", pattern = "*", action = "ask" },
  { permission = "doom_loop", pattern = "*", action = "ask" },
  { permission = "edit", pattern = "*", action = "deny" },
  { permission = "bash", pattern = "*", action = "deny" },
  { permission = "task", pattern = "*", action = "deny" },
  { permission = "external_directory", pattern = "*", action = "deny" },
}

---Builds plugin ownership metadata for a root.
---@param root_hash string
---@return table
function M.metadata(root_hash)
  return { client = "opencode.nvim-inline", contract_version = 2, root_hash = root_hash }
end

---Returns whether rules end with the exact required sequence.
---@param rules table[]
---@return boolean
function M.verify_permissions(rules)
  if #rules < #M.permissions then
    return false
  end
  local offset = #rules - #M.permissions
  for i, expected in ipairs(M.permissions) do
    if not vim.deep_equal(rules[offset + i], expected) then
      return false
    end
  end
  return true
end

local function canonical(path)
  return path and require("opencode.runtime.root").realpath(path) or nil
end

local function archived(session)
  return session.time and session.time.archived or session.archivedAt or session.archived_at
end

---Returns whether a remote Session is owned by this Runtime and safe to expose.
---List entries are filtered by metadata first; a canonical detail directory check is required before reuse.
---This leaves foreign and archived Sessions untouched because their retention belongs to OpenCode.
---@param session table
---@param runtime table
---@param require_directory? boolean
---@return boolean
function M.managed(session, runtime, require_directory)
  local metadata = session.metadata or {}
  if
    metadata.client ~= "opencode.nvim-inline"
    or metadata.contract_version ~= 2
    or metadata.root_hash ~= runtime.root_hash
    or archived(session)
  then
    return false
  end
  return not require_directory or canonical(session.directory) == runtime.root
end

local function status_value(statuses, id)
  local value = statuses and statuses[id]
  if type(value) == "table" then
    return value.type or value.status or value.state
  end
  return value
end

---Derives Session availability from the local Job pointer before remote status.
---A local nonterminal Job remains active through apply and dialogs even if OpenCode reports idle.
---Remote busy without such a Job closes the prompt gate instead of inventing local work.
---@param runtime table
---@param session table
---@param remote_status? string
---@return string, string?
function M.availability(runtime, session, remote_status)
  local job = session.active_job_key and runtime.jobs[session.active_job_key]
  if job and not require("opencode.job").terminal(job.state) and job.session_id == session.id then
    return "active", job.key
  end
  if remote_status == "busy" or remote_status == "running" then
    runtime.prompt_locked, runtime.reconciliation_required = true, true
    return "blocked", "remote_busy_without_job"
  end
  return "reusable"
end

local function activity(session)
  local time = session.time or {}
  return time.updated or time.created or session.updatedAt or session.createdAt or 0
end

---Assigns the shortest collision-free suffix IDs for one picker dataset.
---Lengths grow together until every visible Session is unambiguous, keeping IDs stable for a dataset.
---@param sessions table[]
function M.assign_short_ids(sessions)
  local length = 8
  while true do
    local seen, collision = {}, false
    for _, session in ipairs(sessions) do
      local short = session.id:sub(-length)
      collision = collision or seen[short] == true
      seen[short] = true
    end
    if not collision then
      break
    end
    length = length + 2
  end
  for _, session in ipairs(sessions) do
    session.short_id = session.id:sub(-length)
  end
end

---Loads and verifies the Runtime-local managed Session inventory.
---It checks every metadata candidate through detail GET, then derives availability and activity ordering.
---Only verified details enter the local registry or picker dataset.
---@param runtime table
---@return Promise<table[]>
function M.inventory(runtime)
  local Promise = require("opencode.promise")
  return Promise.all({ runtime.client:list_sessions(), runtime.client:session_status() }):next(function(results)
    local listed, statuses = results[1], results[2]
    local checks = {}
    for _, candidate in ipairs(listed or {}) do
      if M.managed(candidate, runtime, false) then
        table.insert(checks, runtime.client:get_session(candidate.id))
      end
    end
    return Promise.all(checks):next(function(details)
      local sessions = {}
      for _, detail in ipairs(details) do
        if M.managed(detail, runtime, true) then
          local local_session = runtime.sessions[detail.id] or { id = detail.id, root = runtime.root }
          local_session.title = detail.title
          local_session.metadata = vim.deepcopy(detail.metadata)
          local_session.remote_status = status_value(statuses, detail.id) or "idle"
          local_session.last_mode = detail.metadata and detail.metadata.last_mode or local_session.last_mode
          local_session.activity = activity(detail)
          local_session.availability, local_session.availability_reason = M.availability(
            runtime,
            local_session,
            local_session.remote_status
          )
          runtime.sessions[detail.id] = local_session
          table.insert(sessions, local_session)
        end
      end
      M.assign_short_ids(sessions)
      table.sort(sessions, function(a, b)
        if (a.availability == "active") ~= (b.availability == "active") then
          return a.availability == "active"
        end
        return a.activity > b.activity
      end)
      return sessions
    end)
  end)
end

---Appends and verifies the exact permission suffix immediately before Session reuse.
---A fresh detail GET proves ownership, canonical root, and that no later rule can override the profile.
---@param runtime table
---@param session_id string
---@param mode "plan"|"build"
---@return Promise<table>
function M.revalidate(runtime, session_id, mode)
  local metadata = M.metadata(runtime.root_hash)
  metadata.last_mode = mode
  return runtime.client
    :update_session(session_id, { metadata = metadata, permission = M.permissions })
    :next(function()
      return runtime.client:get_session(session_id)
    end)
    :next(function(detail)
      if not M.managed(detail, runtime, true) or not M.verify_permissions(detail.permission or {}) then
        return require("opencode.promise").reject({ error_class = "session_verification" })
      end
      return detail
    end)
end

---Selects one verified local Session in the owned TUI and records it only after success.
---This field is transcript and follow-up UI state; event routing never reads it.
---@param runtime table
---@param session_id string
---@return Promise<table>
function M.select(runtime, session_id)
  local session = runtime.sessions[session_id]
  if not session then
    return require("opencode.promise").reject({ error_class = "unknown_session" })
  end
  return runtime.client:select_session(session_id):next(function()
    runtime.selected_session_id = session_id
    return session
  end)
end

---Returns privacy-safe Session and correlation diagnostics for one Runtime.
---Ownership fields and short identities are included, while titles and message content are omitted.
---@param runtime table
---@return table
function M.diagnostics(runtime)
  local result = { root_hash = runtime.root_hash, correlation = vim.deepcopy(runtime.correlation or {}), sessions = {} }
  for _, session in pairs(runtime.sessions) do
    local job = session.active_job_key and runtime.jobs[session.active_job_key]
    table.insert(result.sessions, {
      short_id = session.short_id,
      managed = session.metadata == nil or session.metadata.client == "opencode.nvim-inline",
      contract_version = session.metadata and session.metadata.contract_version or 2,
      availability = session.availability,
      availability_reason = session.availability_reason,
      active_job = job and job.user_message_id:sub(-8) or nil,
    })
  end
  return result
end

return M
