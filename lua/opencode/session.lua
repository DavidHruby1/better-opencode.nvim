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
---A pending or live Session claim is also active, while remote busy without local work closes the prompt gate instead of
---inventing local work. Terminal claims are discarded when this check observes them.
---@param runtime table
---@param session table
---@param remote_status? string
---@return string, string?
function M.availability(runtime, session, remote_status)
  local job = session.active_job_key and runtime.jobs[session.active_job_key]
  if job and not require("opencode.job").terminal(job.state) and job.session_id == session.id then
    return "active", job.key
  end
  local claim = runtime.session_claims and runtime.session_claims[session.id]
  if claim then
    if type(claim) ~= "table" or claim.pending then
      return "active", "session_claimed"
    end
    local claimed_job = claim.job_key and runtime.jobs[claim.job_key]
    if claimed_job and not require("opencode.job").terminal(claimed_job.state) then
      return "active", claimed_job.key
    end
    runtime.session_claims[session.id] = nil
  end
  if remote_status == "busy" or remote_status == "running" then
    runtime.prompt_locked, runtime.reconciliation_required = true, true
    runtime.reconciliation_blocked = true
    return "blocked", "remote_busy_without_job"
  end
  return "reusable"
end

local function activity(session)
  local time = session.time or {}
  return time.updated or time.created or session.updatedAt or session.createdAt or 0
end

---Finds a nonterminal local Job even when its Session registry entry is missing from a transient inventory response.
---The result protects that Job and its selected pointer from cleanup based only on list omission.
---@param runtime table
---@param session_id string
---@return boolean
local function has_active_job(runtime, session_id)
  for _, job in pairs(runtime.jobs or {}) do
    if job.session_id == session_id and not require("opencode.job").terminal(job.state) then
      return true
    end
  end
  return false
end

---Claims one Session for the short interval between selecting it and registering its Job.
---A pending claim or a live claimed Job rejects another claimant; terminal Job claims are discarded when observed.
---This keeps the existing Runtime table as the single race guard without changing remote Session state.
---@param runtime table
---@param session_id string
---@return table?, string?
function M.claim(runtime, session_id)
  runtime.session_claims = runtime.session_claims or {}
  local session = runtime.sessions and runtime.sessions[session_id]
  local job = session and session.active_job_key and runtime.jobs[session.active_job_key]
  if job and not require("opencode.job").terminal(job.state) then
    return nil, "session_active"
  end
  if has_active_job(runtime, session_id) then
    return nil, "session_active"
  end
  local current = runtime.session_claims[session_id]
  if current then
    if type(current) ~= "table" or current.pending then
      return nil, "session_busy"
    end
    local job = current.job_key and runtime.jobs[current.job_key]
    if job and not require("opencode.job").terminal(job.state) then
      return nil, "session_active"
    end
    runtime.session_claims[session_id] = nil
  end
  local claim = { pending = true, session_id = session_id }
  runtime.session_claims[session_id] = claim
  return claim
end

---Binds a successful prompt claim to its Job so later availability checks can identify its owner.
---The identity check prevents an older failed dispatch from mutating a newer claimant's table entry.
---@param runtime table
---@param session_id string
---@param claim table
---@param job_key string
---@return boolean
function M.bind_claim(runtime, session_id, claim, job_key)
  if runtime.session_claims and runtime.session_claims[session_id] == claim then
    claim.pending = false
    claim.job_key = job_key
    return true
  end
  return false
end

---Releases a claim only when it still belongs to the caller.
---Failed dispatches and delete attempts use this identity check so a late cleanup cannot clear another Session's claim.
---@param runtime table
---@param session_id string
---@param claim table
function M.release_claim(runtime, session_id, claim)
  if runtime.session_claims and runtime.session_claims[session_id] == claim then
    runtime.session_claims[session_id] = nil
  end
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
---It checks every metadata candidate through detail GET, reconciles missing inactive entries, and derives availability and
---activity ordering while normalizing legacy mode metadata for status. Active or blocked local work stays registered when a
---fresh list is incomplete, but confirmed remote absence clears its reusable registry entry and selected pointer.
---A supplied status snapshot avoids requesting /session/status again when startup passes the response to reconciliation.
---@param runtime table
---@param statuses? table
---@return Promise<table[]>
function M.inventory(runtime, statuses)
  local Promise = require("opencode.promise")
  return Promise.all({ runtime.client:list_sessions(), statuses or runtime.client:session_status() })
    :next(function(results)
      local listed, statuses = results[1], results[2]
      local listed_ids = {}
      local checks = {}
      for _, candidate in ipairs(listed or {}) do
        if type(candidate) == "table" and type(candidate.id) == "string" then
          listed_ids[candidate.id] = true
        end
        if type(candidate) == "table" and M.managed(candidate, runtime, false) then
          table.insert(
            checks,
            runtime.client
              :get_session(candidate.id)
              :next(function(detail)
                return { id = candidate.id, detail = detail }
              end)
              :catch(function(err)
                return { id = candidate.id, error = err }
              end)
          )
        end
      end
      return Promise.all(checks):next(function(details)
        local sessions = {}
        local verified_ids = {}
        local confirmed_absence = {}
        local uncertain_details = {}
        for _, checked in ipairs(details) do
          local detail = checked.detail
          local session_id = checked.id
          if detail and M.managed(detail, runtime, true) then
            verified_ids[detail.id] = true
            local local_session = runtime.sessions[detail.id] or { id = detail.id, root = runtime.root }
            local_session.title = detail.title
            local_session.metadata = vim.deepcopy(detail.metadata or {})
            local_session.metadata.last_mode = "build"
            local_session.directory = detail.directory
            local_session.parent_id = detail.parentID or detail.parent_id
            local_session.summary = vim.deepcopy(detail.summary)
            local_session.time = vim.deepcopy(detail.time)
            local_session.remote_status = status_value(statuses, detail.id) or "idle"
            local_session.last_mode = "build"
            local_session.activity = activity(detail)
            local_session.updated = local_session.activity
            local_session.availability, local_session.availability_reason =
              M.availability(runtime, local_session, local_session.remote_status)
            runtime.sessions[detail.id] = local_session
            table.insert(sessions, local_session)
          elseif checked.error and checked.error.status == 404 then
            confirmed_absence[session_id] = true
          elseif checked.error then
            uncertain_details[session_id] = true
          end
        end

        for session_id, local_session in pairs(runtime.sessions) do
          if not verified_ids[session_id] then
            local_session.activity = local_session.activity or 0
            local_session.updated = local_session.updated or local_session.activity
            local_session.availability, local_session.availability_reason =
              M.availability(runtime, local_session, local_session.remote_status)
            local protected = local_session.availability == "active" or local_session.availability == "blocked"
            local remote_absent = not listed_ids[session_id] or confirmed_absence[session_id]
            if remote_absent and not protected and not uncertain_details[session_id] then
              runtime.sessions[session_id] = nil
              if runtime.selected_session_id == session_id then
                runtime.selected_session_id = nil
              end
            elseif protected then
              table.insert(sessions, local_session)
            end
          end
        end
        local selected_id = runtime.selected_session_id
        if
          selected_id
          and (not listed_ids[selected_id] or confirmed_absence[selected_id])
          and not runtime.sessions[selected_id]
          and not (runtime.session_claims and runtime.session_claims[selected_id])
          and not has_active_job(runtime, selected_id)
        then
          runtime.selected_session_id = nil
        end
        M.assign_short_ids(sessions)
        table.sort(sessions, function(a, b)
          if (a.availability == "active") ~= (b.availability == "active") then
            return a.availability == "active"
          end
          return a.activity > b.activity
        end)
        return Promise.resolve(sessions)
      end)
    end)
end

---Verifies a Session before Build reuse, appending the exact permission suffix when it was not supplied by creation.
---The detail GET proves ownership, canonical root, and that no later rule can override the profile. Fresh Sessions
---already received the same Build metadata and permissions in POST, so they skip only the duplicate PATCH.
---The optional boolean skips that duplicate PATCH; an older leading mode value is accepted only for call compatibility
---and ignored.
---Verifies a Session's current ownership, root, and permission suffix without changing remote state.
---@param runtime table
---@param session_id string
---@return Promise<table>
function M.verify(runtime, session_id)
  return runtime.client:get_session(session_id):next(function(detail)
    if not M.managed(detail, runtime, true) or not M.verify_permissions(detail.permission or {}) then
      return require("opencode.promise").reject({ error_class = "session_verification" })
    end
    return detail
  end)
end

---Verifies a Session before Build reuse, appending the exact required metadata and permission suffix when needed.
---The detail GET proves ownership, canonical root, and that no later rule can override the profile. Fresh Sessions
---already received the same Build metadata and permissions in POST, so they skip only the duplicate PATCH.
---The optional boolean skips that duplicate PATCH; an older leading mode value is accepted only for call compatibility
---and ignored.
---@param runtime table
---@param session_id string
---@param skip_update_or_legacy? boolean|string
---@param legacy_skip_update? boolean
---@return Promise<table>
function M.revalidate(runtime, session_id, skip_update_or_legacy, legacy_skip_update)
  local skip_update = type(skip_update_or_legacy) == "boolean" and skip_update_or_legacy or legacy_skip_update
  local metadata = M.metadata(runtime.root_hash)
  metadata.last_mode = "build"
  local update = skip_update and require("opencode.promise").resolve(nil)
    or runtime.client:update_session(session_id, { metadata = metadata, permission = M.permissions })
  return update:next(function()
    return M.verify(runtime, session_id)
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
