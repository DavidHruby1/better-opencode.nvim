local Runtime = {}
Runtime.__index = Runtime

local registry = {}
local active_root
local stale_checked = false
Runtime.registry = registry

local state_transitions = {
  stopped = { starting = true },
  starting = { ready = true, disconnected = true, stopping = true },
  ready = { disconnected = true, stopping = true },
  disconnected = { starting = true, ready = true, stopping = true },
  stopping = { stopped = true },
}

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

local function operations_by_id(value, result)
  if type(value) ~= "table" then
    return
  end
  if type(value.operationId) == "string" then
    result[value.operationId] = value
  end
  for _, child in pairs(value) do
    operations_by_id(child, result)
  end
end

---Expands local OpenAPI references inside request and response contracts for exact comparison.
---Reference cycles retain their reference marker so recursive schemas terminate deterministically.
local function resolve_contract(value, doc, resolving)
  if type(value) ~= "table" then
    return value
  end
  if type(value["$ref"]) == "string" and value["$ref"]:match("^#/") then
    local ref = value["$ref"]
    if resolving[ref] then
      return { ["$ref"] = ref }
    end
    local target = doc
    for segment in ref:gmatch("[^/]+") do
      if segment ~= "#" then
        target = type(target) == "table" and target[segment:gsub("~1", "/"):gsub("~0", "~")] or nil
      end
    end
    resolving[ref] = true
    local resolved = resolve_contract(target, doc, resolving)
    resolving[ref] = nil
    return resolved
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = resolve_contract(child, doc, resolving)
  end
  return result
end

local function operation_contract(operation, doc)
  return {
    parameters = resolve_contract(operation.parameters, doc, {}),
    requestBody = resolve_contract(operation.requestBody, doc, {}),
    responses = resolve_contract(operation.responses, doc, {}),
  }
end

---Polls only the owned Server health endpoint until startup succeeds or the bounded deadline expires.
local function poll_health(runtime, deadline)
  local Promise = require("opencode.promise")
  return Promise.new(function(resolve, reject)
    local function attempt()
      if runtime.state == "stopping" or runtime.state == "stopped" then
        reject({ error_class = "runtime_stopped" })
        return
      end
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

---Combines reconnect defaults with the user-configured runtime retry policy.
local function normalize_status(config)
  local runtime = require("opencode.config").opts.runtime
  config = config or {}
  config.reconnect = config.reconnect or runtime.reconnect
  return config
end

---Checks required operation request and response contracts against the profile's frozen fixture.
---The fixture checksum is verified first so a modified baseline cannot silently redefine compatibility.
---@param doc table
---@param profile table
---@return boolean
---@return string?
function Runtime.verify_doc(doc, profile)
  local raw = table.concat(vim.fn.readfile(profile.fixture, "b"), "\n")
  if vim.fn.sha256(raw) ~= profile.fixture_sha256 then
    return false, "fixture_checksum"
  end
  local expected = vim.json.decode(raw)
  local actual_operations, expected_operations = {}, {}
  operations_by_id(doc, actual_operations)
  operations_by_id(expected, expected_operations)
  for _, id in ipairs(profile.operations) do
    if not actual_operations[id] then
      return false, "missing_operation:" .. id
    end
    if
      not vim.deep_equal(operation_contract(actual_operations[id], doc), operation_contract(expected_operations[id], expected))
    then
      return false, "schema_mismatch:" .. id
    end
  end
  return true
end

---Creates a stopped Runtime containing all process, Session, Job, and recovery state for one canonical root.
---The object is the only routing boundary; module state stores only the root registry and active UI selection.
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
    generation = 0,
    server_generation = 0,
    stream_generation = 0,
    tui_generation = 0,
    reconciling = false,
    sse_live = false,
    prompt_locked = false,
    reconciliation_required = false,
    interaction_locked = false,
    confirmed_requests = {},
    reconnect_attempt = 0,
    lifecycle_generation = 0,
  }, Runtime)
  self.owner_manifest = vim.fn.stdpath("state") .. "/opencode.nvim/runtimes/" .. hash .. ".json"
  self.temp_root = vim.fn.stdpath("state") .. "/opencode.nvim/runtimes/" .. hash
  return self
end

---Reports whether this Runtime can accept a new prompt.
---Readiness, live SSE, reconciliation, and interaction policy are evaluated together so callers never maintain a second gate.
---@return boolean
function Runtime:accepts_prompts()
  return self.state == "ready"
    and self.sse_live
    and not self.reconciling
    and not self.prompt_locked
    and not self.interaction_locked
end

---Moves a Runtime through the recovery lifecycle and rejects impossible state jumps.
---The allowed graph keeps restart, disconnect, and shutdown callbacks from reviving a stopped Runtime.
---@param state string
---@return boolean
function Runtime:transition(state)
  if self.state == state then
    return true
  end
  if not state_transitions[self.state] or not state_transitions[self.state][state] then
    return false
  end
  local old_state = self.state
  self.state = state
  require("opencode.log").write({
    level = "info",
    root_hash = self.root_hash,
    runtime_state = state,
    old_state = old_state,
    new_state = state,
  })
  return true
end

---Rejects effective remote configuration that would add tools or MCP capabilities to the owned proposal boundary.
local function config_valid(runtime, config)
  if next(config.plugin or config.plugins or {}) then
    return false, "custom_plugin"
  end
  for name, enabled in pairs(config.tools or {}) do
    if enabled ~= false and not runtime.profile.tools[name] then
      return false, "custom_tool"
    end
  end
  for _, mcp in pairs(config.mcp or {}) do
    if type(mcp) ~= "table" or mcp.enabled ~= false then
      return false, "enabled_mcp"
    end
  end
  return true
end

---Builds the private ownership record from the current Server and TUI identities.
local function manifest(runtime)
  return {
    schema_version = 1,
    root_hash = runtime.root_hash,
    root = runtime.root,
    port = runtime.port,
    username = runtime.username,
    password = runtime.password,
    nonce = runtime.owner_nonce,
    server = runtime.server_identity,
    tui = runtime.tui_identity,
  }
end

---Atomically replaces the root manifest after a verified process identity changes.
local function write_manifest(runtime)
  runtime.manifest = manifest(runtime)
  require("opencode.runtime.ownership").write(runtime.owner_manifest, runtime.manifest)
end

---Invalidates the current SSE generation before stopping its transport handle.
function Runtime:_invalidate_stream()
  self.stream_generation = self.stream_generation + 1
  self.sse_live = false
  if self.sse then
    vim.fn.jobstop(self.sse)
    self.sse = nil
  end
end

---Marks an unexpected SSE exit disconnected and schedules bounded reconnects without restarting the Server.
local function handle_sse_exit(runtime, generation, code)
  if generation ~= runtime.stream_generation or runtime.state == "stopping" or runtime.state == "stopped" then
    return
  end
  local old_sse = runtime.sse
  runtime.stream_generation = runtime.stream_generation + 1
  runtime.sse = nil
  runtime.sse_live = false
  if old_sse then
    vim.fn.jobstop(old_sse)
  end
  runtime.reconciling = true
  runtime.prompt_locked = true
  runtime:transition("disconnected")
  runtime.reconnect_attempt = runtime.reconnect_attempt + 1
  local reconnect = normalize_status().reconnect
  if runtime.reconnect_attempt > reconnect.max_attempts then
    runtime.reconnect_error = "reconnect_exhausted"
    require("opencode.log").write({
      level = "error",
      root_hash = runtime.root_hash,
      runtime_state = runtime.state,
      error_class = runtime.reconnect_error,
    })
    return
  end
  local delay = math.min(reconnect.max_backoff_ms, reconnect.backoff_ms * 2 ^ (runtime.reconnect_attempt - 1))
  local lifecycle = runtime.lifecycle_generation
  runtime.reconnect_timer = vim.defer_fn(function()
    if runtime.lifecycle_generation ~= lifecycle or runtime.state == "stopping" or runtime.state == "stopped" then
      return
    end
    runtime:connect_sse():catch(function()
      handle_sse_exit(runtime, runtime.stream_generation, code)
    end)
  end, delay)
end

---Opens one root-bound SSE stream and reconciles before reopening prompts after a disconnect.
function Runtime:connect_sse()
  local Promise = require("opencode.promise")
  if not self.client or self.state == "stopping" or self.state == "stopped" then
    return Promise.reject({ error_class = "runtime_not_running" })
  end
  local recovering = self.state == "disconnected"
  self.stream_generation = self.stream_generation + 1
  if self.sse then
    vim.fn.jobstop(self.sse)
    self.sse = nil
  end
  self.generation = self.generation + 1
  local generation = self.stream_generation
  self.sse_live = false
  self.sse = self.client:subscribe(function(event)
    if generation == self.stream_generation and self.state ~= "stopping" and self.state ~= "stopped" then
      self.reconnect_attempt = 0
      self:route_event(event)
    end
  end, function(code)
    handle_sse_exit(self, generation, code)
  end)
  if self.sse <= 0 then
    return Promise.reject({ error_class = "sse_spawn" })
  end
  self.sse_live = true
  if recovering then
    return require("opencode.runtime.reconcile").run(self, self.generation)
  end
  return Promise.resolve(self)
end

---Starts one owned Server generation, writes its manifest, and creates a Runtime-bound client.
local function spawn_server(runtime)
  runtime.server_generation = runtime.server_generation + 1
  runtime.generation = runtime.generation + 1
  local generation = runtime.server_generation
  runtime.port, runtime.username, runtime.password, runtime.owner_nonce =
    free_port(), "opencode", random_hex(32), random_hex(16)
  local binary = require("opencode.config").opts.runtime.binary
  runtime.server_job = vim.fn.jobstart(
    { binary, "serve", "--hostname", runtime.host, "--port", tostring(runtime.port) },
    {
      cwd = runtime.root,
      env = { OPENCODE_SERVER_USERNAME = runtime.username, OPENCODE_SERVER_PASSWORD = runtime.password },
      on_exit = function()
        if generation == runtime.server_generation and runtime.state ~= "stopping" and runtime.state ~= "stopped" then
          runtime:on_server_exit(generation)
        end
      end,
    }
  )
  if runtime.server_job <= 0 then
    return nil, { error_class = "server_spawn" }
  end
  runtime.server_identity = require("opencode.runtime.ownership").identity(vim.fn.jobpid(runtime.server_job))
  if not runtime.server_identity then
    vim.fn.jobstop(runtime.server_job)
    return nil, { error_class = "process_identity" }
  end
  write_manifest(runtime)
  runtime.client = require("opencode.client").new({
    host = runtime.host,
    port = runtime.port,
    username = runtime.username,
    password = runtime.password,
    root = runtime.root,
    runtime = runtime,
  })
  return runtime
end

---Starts the single TUI client for a Runtime and restores its selected transcript after attach.
local function start_tui(runtime)
  runtime.tui_generation = runtime.tui_generation + 1
  local sidebar, err = require("opencode.ui.sidebar").new(runtime)
  if not sidebar then
    return require("opencode.promise").reject({ error_class = err })
  end
  runtime.sidebar = sidebar
  runtime.tui_identity = require("opencode.runtime.ownership").identity(vim.fn.jobpid(sidebar.job))
  if not runtime.tui_identity then
    sidebar:stop()
    return require("opencode.promise").reject({ error_class = "tui_identity" })
  end
  write_manifest(runtime)
  local selected = runtime.selected_session_id and runtime.sessions[runtime.selected_session_id]
  local selection = selected and runtime.client:select_session(selected.id) or require("opencode.promise").resolve(nil)
  return selection
    :catch(function()
      return nil
    end)
    :next(function()
      return runtime
    end)
end

---Loads persisted managed Sessions and runs the same exact recovery snapshot used after reconnect.
local function initial_reconcile(runtime)
  local Promise = require("opencode.promise")
  return require("opencode.session")
    .inventory(runtime)
    :catch(function()
      return {}
    end)
    :next(function()
      return require("opencode.runtime.reconcile").run(runtime, runtime.generation)
    end)
    :catch(function(err)
      runtime.reconciling = false
      runtime.prompt_locked = true
      runtime.reconcile_error = err
      return Promise.reject(err)
    end)
end

---Starts or restarts only the owned Server/TUI pair, performs compatibility preflight, and opens prompts after reconciliation.
---A disconnected Runtime is restarted in place so local Job snapshots and edit marks survive until fail-closed reconciliation decides them.
---@return Promise<table>
function Runtime:start()
  local Promise = require("opencode.promise")
  if self.state == "ready" then
    return Promise.resolve(self)
  end
  if self.state == "starting" then
    return self.start_promise or Promise.reject({ error_class = "runtime_busy" })
  end
  if self.state == "stopping" then
    return Promise.reject({ error_class = "runtime_stopping" })
  end
  self.lifecycle_generation = self.lifecycle_generation + 1
  self:transition("starting")
  self.prompt_locked = true
  self.reconciling = true
  local guard_ok, guard_error = require("opencode.runtime.config_guard").scan(self.root)
  if not guard_ok then
    self:stop()
    return Promise.reject({ error_class = guard_error })
  end
  if not stale_checked then
    stale_checked = true
    if not require("opencode.runtime.ownership").cleanup_stale_manifests() then
      self:stop()
      return Promise.reject({ error_class = "manual_cleanup" })
    end
  end
  local spawned, spawn_error = spawn_server(self)
  if not spawned then
    self:stop()
    return Promise.reject(spawn_error)
  end
  local timeout = require("opencode.config").opts.runtime.startup_timeout
  local start_promise = poll_health(self, vim.uv.now() + timeout)
    :next(function(health)
      self.profile = require("opencode.compat")[health.version]
      if not self.profile then
        return Promise.reject({ error_class = "unsupported_version" })
      end
      self.client.profile = self.profile
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
      local ok, err = config_valid(self, config)
      if not ok then
        return Promise.reject({ error_class = err })
      end
      return self.client:agents()
    end)
    :next(function(agents)
      self.agents = agents
      return self:connect_sse()
    end)
    :next(function()
      if self.state ~= "starting" or not self.sse_live then
        return Promise.reject({ error_class = "sse_disconnected" })
      end
      return start_tui(self)
    end)
    :next(function()
      self:transition("ready")
      return initial_reconcile(self)
    end)
    :next(function()
      require("opencode.log").write({ level = "info", root_hash = self.root_hash, runtime_state = self.state })
      return self
    end)
    :catch(function(err)
      if self.state ~= "stopping" then
        self:stop()
      end
      return Promise.reject(err)
    end)
  self.start_promise = start_promise
  return start_promise
end

function Runtime:on_server_exit(generation)
  if generation ~= self.server_generation or self.state == "stopping" or self.state == "stopped" then
    return
  end
  self:transition("disconnected")
  self.server_generation = self.server_generation + 1
  self.generation = self.generation + 1
  self.prompt_locked = true
  self.reconciling = true
  self.sse_live = false
  self.stream_generation = self.stream_generation + 1
  self.tui_generation = self.tui_generation + 1
  if self.sse then
    vim.fn.jobstop(self.sse)
    self.sse = nil
  end
  if self.sidebar then
    self.sidebar:dead()
  end
  if self.client then
    self.client:cancel_requests()
  end
  require("opencode.log").write({
    level = "error",
    root_hash = self.root_hash,
    runtime_state = self.state,
    error_class = "server_exit",
  })
end

---Recovers only a dead TUI when the owning Server and Runtime generation remain valid.
---A Server crash leaves the terminal hidden for explicit Runtime restart instead of attaching to an unverified endpoint.
---@param generation integer
function Runtime:handle_tui_exit(generation)
  if generation ~= self.tui_generation or self.state ~= "ready" or not self.sse_live then
    return
  end
  self:retry_tui():catch(function() end)
end

---Restarts an explicitly disconnected owned Runtime and reconciles its persisted Session state before prompts reopen.
---@return Promise<table>
function Runtime:restart()
  if self.state ~= "disconnected" then
    return require("opencode.promise").reject({ error_class = "runtime_not_disconnected" })
  end
  return self:start()
end

---Retries a failed TUI attach without changing Server, SSE, Session, or Job state.
---@return Promise<table>
function Runtime:retry_tui()
  if not self.sidebar or self.tui_recovering or self.state == "stopping" or self.state == "stopped" then
    return require("opencode.promise").reject({ error_class = "tui_unavailable" })
  end
  self.tui_recovering = true
  return self.sidebar:recover():finally(function()
    self.tui_recovering = false
  end)
end

---Routes events through the owning Runtime and exact Session/Job identities.
---Idle completion reads the full exact Session message list so SSE loss and duplicate idle events share one completion guard.
---@param event table
function Runtime:route_event(event)
  if self.reconciling and event.type ~= "server.connected" then
    local properties = event.properties or {}
    local info = properties.info or properties
    if
      event.type == "question.replied"
      or event.type == "question.rejected"
      or event.type == "permission.replied"
      or event.type == "permission.rejected"
    then
      local session_id = info.sessionID or properties.sessionID
      local request_id = info.requestID or properties.requestID or info.id
      local session = session_id and self.sessions[session_id]
      local job = session and session.active_job_key and self.jobs[session.active_job_key]
      if job and request_id then
        self.confirmed_requests[job.key .. ":" .. request_id] = self.generation
      end
    end
    self.buffered_events = self.buffered_events or {}
    table.insert(self.buffered_events, { generation = self.stream_generation, event = event })
    return
  end
  if require("opencode.events").route(self, event) then
    return
  end
  local properties = event.properties or {}
  local info = properties.info or properties.message or properties
  if event.type == "server.connected" then
    if self.state == "disconnected" then
      self:begin_reconciliation()
    end
    return
  end
  if event.type == "session.error" then
    local session_id = properties.sessionID or info.sessionID
    local message_id = properties.messageID or info.parentID or info.messageID
    local job = message_id and self.jobs[session_id .. ":" .. message_id]
    local session = job and self.sessions[job.session_id]
    if job and not require("opencode.job").terminal(job.state) then
      job.error_class = "session_error"
      require("opencode.job").finish(job, session, "error")
    else
      self:begin_reconciliation()
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
      self:begin_reconciliation()
    end
    return
  end
  if event.type ~= "session.idle" then
    return
  end
  local session_id = properties.sessionID or info.sessionID
  local session = self.sessions[session_id]
  local job = session and self.jobs[session.active_job_key]
  if not job or job.state ~= "running" then
    return
  end
  job.remote_idle = true
  local attempts = 0
  local function load_messages()
    attempts = attempts + 1
    self.client
      :messages(session_id)
      :next(function(messages)
        if job.state ~= "running" or session.active_job_key ~= job.key then
          return
        end
        local reconcile = require("opencode.runtime.reconcile")
        if not reconcile.has_parent_response(job, messages) then
          job.remote_idle = false
          self.correlation.late = self.correlation.late + 1
          return
        end
        reconcile.complete_job(self, session, job, messages)
      end)
      :catch(function(err)
        if job.state ~= "running" then
          return
        end
        if type(err) == "table" and err.status == 400 then
          local captured = vim.tbl_values(job.assistant_messages or {})
          local reconcile = require("opencode.runtime.reconcile")
          if reconcile.has_parent_response(job, captured) then
            reconcile.complete_job(self, session, job, captured)
            return
          end
          job.remote_idle = false
          self.correlation.late = self.correlation.late + 1
          return
        end
        job.error_class = type(err) == "table" and err.error_class or "message_reconciliation"
        job.error_endpoint = type(err) == "table" and err.endpoint or nil
        job.error_status = type(err) == "table" and err.status or nil
        require("opencode.job").finish(job, session, "error")
      end)
  end
  load_messages()
end

---Starts a bounded reconciliation snapshot for an already-connected Runtime.
---The generation guard prevents an older snapshot from reopening prompts after a restart or shutdown.
function Runtime:begin_reconciliation()
  if self.reconciling or self.state == "stopping" or self.state == "stopped" then
    return
  end
  self.reconciling = true
  self.prompt_locked = true
  local ok, promise = pcall(require("opencode.runtime.reconcile").run, self, self.generation)
  if not ok then
    self.reconciling = false
    self.reconcile_error = promise
    return
  end
  promise:catch(function() end)
end

---Stops every owned process and local Job callback with a bounded, ownership-verified shutdown.
---Abort failures do not prevent other Runtime cleanup, and a manifest remains when process ownership cannot be proven.
function Runtime:stop()
  if self.state == "stopped" or self.state == "stopping" then
    return
  end
  self.lifecycle_generation = self.lifecycle_generation + 1
  self:transition("stopping")
  self.server_generation = self.server_generation + 1
  self.tui_generation = self.tui_generation + 1
  self.prompt_locked = true
  self.reconciling = false
  self:_invalidate_stream()
  if self.reconnect_timer then
    pcall(function()
      self.reconnect_timer:stop()
    end)
    self.reconnect_timer = nil
  end
  local job = require("opencode.job")
  local keys = {}
  for key, item in pairs(self.jobs) do
    if not job.terminal(item.state) then
      table.insert(keys, key)
    end
  end
  for _, key in ipairs(keys) do
    job.cancel(self, key)
  end
  vim.fn.delete(self.temp_root, "rf")
  if self.client then
    self.client:cancel_requests()
  end
  if self.sidebar then
    self.sidebar:stop()
  end
  if self.server_job then
    local verified, running = require("opencode.runtime.ownership").verified(self.server_identity)
    if verified and running then
      require("opencode.runtime.ownership").signal(self.server_identity)
      vim.fn.jobstop(self.server_job)
    end
  end
  local shutdown_timeout = require("opencode.config").opts.runtime.shutdown_timeout
  local ownership = require("opencode.runtime.ownership")
  vim.wait(shutdown_timeout, function()
    local server_gone = not self.server_identity or not ownership.identity(self.server_identity.pid)
    local tui_gone = not self.tui_identity or not ownership.identity(self.tui_identity.pid)
    return server_gone and tui_gone
  end, 20)
  if self.manifest then
    local removed = ownership.shutdown(self.owner_manifest, self.manifest)
    if removed then
      self.manifest = nil
    end
  end
  if self.client then
    self.client = nil
  end
  self:transition("stopped")
  if registry[self.root] == self then
    registry[self.root] = nil
  end
  if active_root == self.root then
    active_root = nil
    Runtime.active_root = nil
  end
end

---Returns the Runtime for a captured buffer root, creating and activating only that root.
---Symlink aliases are canonicalized before registry lookup, so one root owns one Server/TUI/SSE set.
---@param capture table
---@return Promise<table>
function Runtime.get_or_start(capture)
  local Promise = require("opencode.promise")
  local root, err = require("opencode.runtime.root").resolve(capture)
  if not root then
    return Promise.reject({ error_class = err })
  end
  local runtime = registry[root]
  if not runtime then
    runtime = Runtime.new(root)
    registry[root] = runtime
  end
  if runtime.state == "disconnected" then
    return Promise.reject({ error_class = "runtime_disconnected" })
  end
  if runtime.state == "ready" then
    active_root = root
    Runtime.active_root = root
    return Promise.resolve(runtime)
  end
  return runtime:start():next(function(value)
    active_root = root
    Runtime.active_root = root
    return value
  end)
end

---Returns the Runtime selected for sidebar and command UI, never for event or HTTP routing.
---@return table?
function Runtime.current()
  return active_root and registry[active_root] or nil
end

---Returns a Runtime by canonical root for callbacks carrying immutable root identity.
---@param root string
---@return table?
function Runtime.for_root(root)
  local canonical = require("opencode.runtime.root").realpath(root) or root
  return registry[canonical]
end

---Returns a stable snapshot of every registered Runtime for cross-root commands and shutdown.
---@return table[]
function Runtime.all()
  local result = {}
  for _, runtime in pairs(registry) do
    table.insert(result, runtime)
  end
  table.sort(result, function(a, b)
    return a.root < b.root
  end)
  return result
end

---Makes one Runtime's TUI the visible sidebar buffer without stopping any other root.
---@param root string
---@return table?
function Runtime.show_root(root)
  root = require("opencode.runtime.root").realpath(root) or root
  local runtime = registry[root]
  if not runtime then
    return nil
  end
  active_root = root
  Runtime.active_root = root
  if runtime.sidebar then
    runtime.sidebar:show_root(runtime)
  end
  return runtime
end

---Cancels a root-keyed snapshot across all Runtime objects and reports only aggregate counts.
---Each cancel-one call keeps its owning Runtime, while settled promises ensure one failed abort cannot stop other roots.
---@return Promise<table>
function Runtime.cancel_all()
  local Promise = require("opencode.promise")
  local snapshot = {}
  for _, runtime in ipairs(Runtime.all()) do
    for key, job in pairs(runtime.jobs) do
      if not require("opencode.job").terminal(job.state) then
        table.insert(snapshot, { runtime = runtime, key = key })
      end
    end
  end
  local requests = {}
  for _, item in ipairs(snapshot) do
    table.insert(requests, require("opencode.job").cancel(item.runtime, item.key))
  end
  return Promise.all_settled(requests):next(function(results)
    local report = { requested = #snapshot, cancelled = 0, abort_failed = 0 }
    for _, result in ipairs(results) do
      if result.status == "fulfilled" then
        report.cancelled = report.cancelled + (result.value.cancelled or 0)
        report.abort_failed = report.abort_failed + (result.value.errors or 0)
      else
        report.abort_failed = report.abort_failed + 1
      end
    end
    return report
  end)
end

---Shuts down a stable snapshot of every Runtime and isolates cleanup failures by root.
---Each Runtime performs its own bounded ownership checks; an uncertain manifest remains for manual diagnosis.
function Runtime.shutdown()
  for _, runtime in ipairs(Runtime.all()) do
    local ok = pcall(runtime.stop, runtime)
    if not ok then
      require("opencode.log").write({
        level = "error",
        root_hash = runtime.root_hash,
        runtime_state = runtime.state,
        error_class = "shutdown_cleanup",
      })
    end
  end
end

local group = vim.api.nvim_create_augroup("OpencodeRuntime", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    Runtime.shutdown()
  end,
})

return Runtime
