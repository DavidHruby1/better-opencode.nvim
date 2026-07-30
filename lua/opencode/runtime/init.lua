local Runtime = {}
Runtime.__index = Runtime

local current

local function random_hex(bytes)
  return (assert(vim.uv.random(bytes)):gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

local function free_port()
  local tcp = assert(vim.uv.new_tcp())
  assert(tcp:bind("127.0.0.1", 0))
  local port = assert(tcp:getsockname()).port
  tcp:close()
  return port
end

local function operation_ids(value, result)
  if type(value) ~= "table" then
    return
  end
  if type(value.operationId) == "string" then
    result[value.operationId] = true
  end
  for _, child in pairs(value) do
    operation_ids(child, result)
  end
end

---Checks that a captured OpenAPI document exposes every operation required by a profile.
---@param doc table
---@param profile table
---@return boolean
---@return string?
function Runtime.verify_doc(doc, profile)
  local ids = {}
  operation_ids(doc, ids)
  for _, id in ipairs(profile.operations) do
    if not ids[id] then
      return false, "missing_operation:" .. id
    end
  end
  return true
end

local function poll_health(runtime, deadline)
  local Promise = require("opencode.promise")
  return Promise.new(function(resolve, reject)
    local function attempt()
      runtime.client:health():next(resolve):catch(function()
        if vim.uv.now() >= deadline then
          reject({ error_class = "startup_timeout" })
        else
          vim.defer_fn(attempt, 100)
        end
      end)
    end
    vim.defer_fn(attempt, 250)
  end)
end

---Creates a stopped Runtime object for one canonical root.
---@param root string
---@return table
function Runtime.new(root)
  local hash = vim.fn.sha256(root)
  local self = setmetatable({
    root = root,
    root_hash = hash,
    state = "stopped",
    host = "127.0.0.1",
    sessions = {},
    jobs = {},
    assistant_jobs = {},
    correlation = { exact = 0, late = 0, unknown = 0 },
  }, Runtime)
  self.owner_manifest = vim.fn.stdpath("state") .. "/opencode.nvim/runtimes/" .. hash .. ".json"
  return self
end

---Starts and verifies the owned Server and TUI before opening the prompt gate.
---Every failure rolls back only this Runtime's handles and leaves no fallback URL.
---@return Promise<table>
function Runtime:start()
  local Promise = require("opencode.promise")
  if self.state == "ready" then
    return Promise.resolve(self)
  end
  if self.state ~= "stopped" then
    return Promise.reject({ error_class = "runtime_busy" })
  end
  self.state = "starting"
  local guard_ok, guard_error = require("opencode.runtime.config_guard").scan(self.root)
  if not guard_ok then
    self.state = "stopped"
    return Promise.reject({ error_class = guard_error })
  end
  if not require("opencode.runtime.ownership").cleanup_stale(self.owner_manifest, self.root) then
    self.state = "stopped"
    return Promise.reject({ error_class = "manual_cleanup" })
  end
  self.port, self.username, self.password, self.owner_nonce = free_port(), "opencode", random_hex(32), random_hex(16)
  self.server_job = vim.fn.jobstart({ "opencode", "serve", "--hostname", self.host, "--port", tostring(self.port) }, {
    cwd = self.root,
    env = { OPENCODE_SERVER_USERNAME = self.username, OPENCODE_SERVER_PASSWORD = self.password },
    on_exit = function()
      if self.state == "ready" then
        self.state = "stopped"
      end
    end,
  })
  if self.server_job <= 0 then
    self.state = "stopped"
    return Promise.reject({ error_class = "server_spawn" })
  end
  local pid = vim.fn.jobpid(self.server_job)
  local identity = require("opencode.runtime.ownership").identity(pid)
  if not identity then
    self:stop()
    return Promise.reject({ error_class = "process_identity" })
  end
  self.manifest = {
    schema_version = 1,
    root_hash = self.root_hash,
    port = self.port,
    username = self.username,
    password = self.password,
    nonce = self.owner_nonce,
    server = identity,
  }
  require("opencode.runtime.ownership").write(self.owner_manifest, self.manifest)
  self.client = require("opencode.client").new(self)
  local timeout = require("opencode.config").opts.runtime.startup_timeout
  return poll_health(self, vim.uv.now() + timeout)
    :next(function(health)
      self.profile = require("opencode.compat")[health.version]
      if not self.profile then
        return Promise.reject({ error_class = "unsupported_version" })
      end
      return self.client:doc()
    end)
    :next(function(doc)
      local ok, err = Runtime.verify_doc(doc, self.profile)
      if not ok then
        return Promise.reject({ error_class = err })
      end
      return self.client:path()
    end)
    :next(function(path)
      local directory = require("opencode.runtime.root").realpath(path.directory or path.worktree or "")
      if directory ~= self.root then
        return Promise.reject({ error_class = "root_mismatch" })
      end
      return self.client:config()
    end)
    :next(function(config)
      if next(config.plugin or config.plugins or {}) then
        return Promise.reject({ error_class = "custom_plugin" })
      end
      for name, enabled in pairs(config.tools or {}) do
        if enabled ~= false and not self.profile.tools[name] then
          return Promise.reject({ error_class = "custom_tool" })
        end
      end
      for _, mcp in pairs(config.mcp or {}) do
        if type(mcp) ~= "table" or mcp.enabled ~= false then
          return Promise.reject({ error_class = "enabled_mcp" })
        end
      end
      return self.client:agents()
    end)
    :next(function(agents)
      self.agents = agents
      self.sse = self.client:subscribe(function(event)
        self:route_event(event)
      end, function() end)
      local sidebar, err = require("opencode.ui.sidebar").new(self)
      if not sidebar then
        return Promise.reject({ error_class = err })
      end
      self.sidebar = sidebar
      self.manifest.tui = require("opencode.runtime.ownership").identity(vim.fn.jobpid(sidebar.job))
      require("opencode.runtime.ownership").write(self.owner_manifest, self.manifest)
      self.state = "ready"
      require("opencode.log").write({ level = "info", root_hash = self.root_hash, runtime_state = self.state })
      return Promise.resolve(self)
    end)
    :catch(function(err)
      self:stop()
      return Promise.reject(err)
    end)
end

local function finish_build(runtime, session, job, messages)
  local structured = {}
  for _, message in ipairs(messages or {}) do
    local info = message.info or message
    if
      info.role == "assistant"
      and info.parentID == job.user_message_id
      and job.assistant_message_ids[info.id]
      and type(info.structured) == "table"
    then
      table.insert(structured, { id = info.id, value = info.structured })
    end
  end
  if #structured ~= 1 then
    job.error_class = "structured_output_count"
    require("opencode.job").transition(job, "error", { session = session })
    return
  end
  local validated, err = require("opencode.proposal").validate(structured[1].value, job)
  if not validated then
    job.error_class = err and err.error_class or "proposal_validation"
    require("opencode.job").transition(
      job,
      err and err.error_class == "scope_violation" and "scope_violation" or "error",
      {
        session = session,
      }
    )
    return
  end
  job.structured_assistant_message_id = structured[1].id
  job.proposal, job.theirs = validated.proposal, validated.theirs
  require("opencode.job").transition(job, "pending_apply", { session = session })
  if job.auto_apply then
    require("opencode.apply").start(job, runtime)
  end
end

---Routes only events correlated to a registered local Plan or Build Job.
---@param event table
function Runtime:route_event(event)
  if require("opencode.events").route(self, event) then
    return
  end
  local properties = event.properties or {}
  local info = properties.info or properties.message or properties
  if event.type == "session.error" then
    local session_id = properties.sessionID or info.sessionID
    local message_id = properties.messageID or info.parentID or info.messageID
    local job = message_id and self.jobs[session_id .. ":" .. message_id]
    local session = job and self.sessions[job.session_id]
    if job and not require("opencode.job").terminal(job.state) then
      job.error_class = "session_error"
      require("opencode.job").finish(job, session, "error")
    else
      self.prompt_locked, self.reconciliation_required = true, true
    end
    return
  end
  if event.type == "file.edited" then
    local session_id = properties.sessionID or info.sessionID
    local message_id = properties.messageID or info.parentID or info.messageID
    local job = message_id and self.jobs[session_id .. ":" .. message_id]
    local session = job and self.sessions[job.session_id]
    if job and job.mode == "build" and job.state == "running" then
      job.error_class = "file_edited"
      require("opencode.job").transition(job, "error", { session = session })
    else
      self.prompt_locked, self.reconciliation_required = true, true
    end
    return
  end
  if event.type ~= "session.idle" then
    return
  end
  local session_id = properties.sessionID or info.sessionID
  local session = self.sessions[session_id]
  if session then
    session.remote_status = "idle"
  end
  local job = session and self.jobs[session.active_job_key]
  if not job or job.state ~= "running" then
    return
  end
  job.remote_idle = true
  -- Completes only the Job captured for this idle event from its exact message list.
  local function accept_messages(messages)
    if job.state ~= "running" or session.active_job_key ~= job.key then
      return
    end
    local has_response = false
    for _, message in ipairs(messages or {}) do
      local message_info = message.info or message
      if
        message_info.role == "assistant"
        and message_info.parentID == job.user_message_id
        and job.assistant_message_ids[message_info.id]
      then
        has_response = true
        break
      end
    end
    if not has_response then
      job.late_event_count = (job.late_event_count or 0) + 1
      self.correlation.late = self.correlation.late + 1
      job.remote_idle, session.remote_status = false, "busy"
      return
    end
    if job.mode == "build" then
      finish_build(self, session, job, messages)
      return
    end
    require("opencode.job").finish(job, session, "completed")
  end
  -- Loads only assistant IDs already bootstrapped from this Job's exact parent.
  local function fetch_messages(attempt)
    local live = {}
    local has_structured = false
    for _, message in pairs(job.assistant_messages or {}) do
      table.insert(live, message)
      has_structured = has_structured or type(message.info.structured) == "table"
    end
    if #live > 0 and (job.mode == "plan" or has_structured) then
      accept_messages(live)
      return
    end
    local requests = {}
    for assistant_id in pairs(job.assistant_message_ids) do
      table.insert(requests, self.client:message(session_id, assistant_id))
    end
    if #requests == 0 then
      job.late_event_count = (job.late_event_count or 0) + 1
      self.correlation.late = self.correlation.late + 1
      job.remote_idle, session.remote_status = false, "busy"
      return
    end
    require("opencode.promise").all(requests):next(accept_messages):catch(function(err)
      if job.state == "running" and type(err) == "table" and err.status == 400 then
        if attempt < 3 then
          vim.defer_fn(function()
            fetch_messages(attempt + 1)
          end, 100)
        else
          job.late_event_count = (job.late_event_count or 0) + 1
          self.correlation.late = self.correlation.late + 1
          job.remote_idle, session.remote_status = false, "busy"
        end
        return
      end
      job.error_class = type(err) == "table" and err.error_class or "message_reconciliation"
      job.error_endpoint = type(err) == "table" and err.endpoint or nil
      job.error_status = type(err) == "table" and err.status or nil
      require("opencode.job").finish(job, session, "error")
    end)
  end
  fetch_messages(1)
end

---Stops this Runtime idempotently and removes only its verified manifest.
function Runtime:stop()
  if self.state == "stopped" or self.state == "stopping" then
    return
  end
  self.state = "stopping"
  if self.sidebar then
    self.sidebar:stop()
  end
  if self.sse then
    vim.fn.jobstop(self.sse)
  end
  if self.server_job then
    vim.fn.jobstop(self.server_job)
  end
  if self.owner_manifest then
    vim.uv.fs_unlink(self.owner_manifest)
  end
  self.state = "stopped"
  if current == self then
    current = nil
  end
end

---Returns the single F01 Runtime, creating it for the capture's canonical root when absent.
---@param capture table
---@return Promise<table>
function Runtime.get_or_start(capture)
  local Promise = require("opencode.promise")
  local root, err = require("opencode.runtime.root").resolve(capture)
  if not root then
    return Promise.reject({ error_class = err })
  end
  if current and current.root ~= root then
    return Promise.reject({ error_class = "single_root_only" })
  end
  current = current or Runtime.new(root)
  return current:start()
end

function Runtime.current()
  return current
end

local group = vim.api.nvim_create_augroup("OpencodeRuntime", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if current then
      current:stop()
    end
  end,
})

return Runtime
