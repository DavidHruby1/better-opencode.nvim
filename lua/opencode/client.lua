local Client = {}
Client.__index = Client

---Creates a root-routed authenticated OpenCode client.
---@param opts { host: string, port: integer, username: string, password: string, root: string, runner?: function, runtime?: table }
---@return table
function Client.new(opts)
  local self = setmetatable({
    host = opts.host,
    port = opts.port,
    username = opts.username,
    password = opts.password,
    root = opts.root,
    runner = opts.runner or vim.system,
    runtime = opts.runtime,
    requests = {},
    closed = false,
    generation = 0,
    stream_generation = 0,
    stream_job = nil,
    stream_timer = nil,
    url = "",
  }, Client)
  self.url = string.format("http://%s:%d", self.host, self.port)
  return self
end

local function request_error(endpoint, code, status)
  return { error_class = (code == 28 or code == 124) and "timeout" or "http", endpoint = endpoint, status = status }
end

local function config_value(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---Builds curl configuration supplied through stdin so credentials and request content never enter process argv.
---Curl parses this before making the request; quoting preserves JSON and authentication bytes exactly.
local function curl_config(username, password, body)
  local lines = { "user = " .. config_value(username .. ":" .. password) }
  if body then
    table.insert(lines, "data-binary = " .. config_value(vim.json.encode(body)))
  end
  return table.concat(lines, "\n") .. "\n"
end

---Sends one JSON request with mandatory authentication and root routing.
---Each request owns one settlement record so cancellation and duplicate process callbacks cannot leave it pending or settle it twice.
---Only status metadata escapes on failure; response bodies are never included in errors or logs.
---@param method string
---@param endpoint string
---@param body? table
---@return Promise<any>
function Client:request(method, endpoint, body)
  local Promise = require("opencode.promise")
  if self.closed then
    return Promise.reject({ error_class = "transport_closed", endpoint = endpoint })
  end
  local request_generation = self.runtime and self.runtime.generation
  local client_generation = self.generation
  return Promise.new(function(resolve, reject)
    local marker = "__OPENCODE_STATUS__:"
    local timeout = endpoint == "/global/health" and "1" or "10"
    local cmd = {
      "curl",
      "--silent",
      "--show-error",
      "--connect-timeout",
      "1",
      "--max-time",
      timeout,
      "--config",
      "-",
      "-X",
      method,
      "-H",
      "Content-Type: application/json",
      "-H",
      "Accept: application/json",
      "-H",
      "x-opencode-directory: " .. self.root,
      "-w",
      marker .. "%{http_code}",
    }
    table.insert(cmd, self.url .. endpoint)
    local request = { settled = false, reject = reject, endpoint = endpoint }
    self.requests[request] = true
    local function settle(ok, value)
      if request.settled then
        return
      end
      request.settled = true
      self.requests[request] = nil
      if ok then
        resolve(value)
      else
        reject(value)
      end
    end
    local ok, process = pcall(
      self.runner,
      cmd,
      { text = true, stdin = curl_config(self.username, self.password, body) },
      function(result)
        if request.settled or self.closed or self.generation ~= client_generation then
          return
        end
        vim.schedule(function()
          if request.settled then
            return
          end
          if self.closed or self.generation ~= client_generation then
            settle(false, { error_class = "transport_closed", endpoint = endpoint })
            return
          end
          if
            self.runtime
            and (
              self.runtime.generation ~= request_generation
              or self.runtime.state == "stopping"
              or self.runtime.state == "stopped"
            )
          then
            settle(false, { error_class = "stale_generation", endpoint = endpoint })
            return
          end
          local payload, status = (result.stdout or ""):match("^(.*)__OPENCODE_STATUS__:(%d%d%d)$")
          status = tonumber(status)
          if result.code ~= 0 or not status or status >= 400 then
            settle(false, request_error(endpoint, result.code, status))
            return
          end
          if status == 204 or payload == "" then
            settle(true, nil)
            return
          end
          local ok, decoded = pcall(vim.json.decode, payload)
          if not ok then
            settle(false, { error_class = "decode", endpoint = endpoint, status = status })
            return
          end
          settle(true, decoded)
        end)
      end
    )
    if not ok then
      settle(false, { error_class = "http", endpoint = endpoint })
      return
    end
    request.process = process
  end)
end

---Closes this client, rejects every in-flight request, and cancels its SSE liveness deadline.
---The generation changes before transports are stopped so synchronous and late callbacks cannot affect Runtime state.
function Client:cancel_requests()
  if self.closed then
    return
  end
  self.closed = true
  self.generation = self.generation + 1
  self.stream_generation = self.stream_generation + 1
  if self.stream_timer then
    pcall(self.stream_timer.stop, self.stream_timer)
    local ok, closing = pcall(self.stream_timer.is_closing, self.stream_timer)
    if not ok or not closing then
      pcall(self.stream_timer.close, self.stream_timer)
    end
    self.stream_timer = nil
  end
  if self.stream_job then
    pcall(vim.fn.jobstop, self.stream_job)
    self.stream_job = nil
  end
  local requests = self.requests
  self.requests = {}
  for request in pairs(requests) do
    request.settled = true
    request.reject({ error_class = "transport_closed", endpoint = request.endpoint })
    local process = request.process
    if process and process.kill then
      pcall(process.kill, process, "sigterm")
    end
  end
end

function Client:health()
  return self:request("GET", "/global/health")
end
function Client:doc()
  return self:request("GET", "/doc")
end
function Client:path()
  return self:request("GET", "/path")
end
function Client:config()
  return self:request("GET", "/config")
end
function Client:agents()
  return self:request("GET", "/agent")
end
function Client:create_session(body)
  return self:request("POST", "/session", body)
end
function Client:list_sessions()
  return self:request("GET", "/session")
end
function Client:session_status()
  return self:request("GET", "/session/status")
end
function Client:update_session(id, body)
  return self:request("PATCH", "/session/" .. id, body)
end
function Client:delete_session(id)
  return self:request("DELETE", "/session/" .. id)
end

---Rejects a Session response whose returned directory is not the client's canonical root.
local function verify_session_root(client, value)
  local directory = value and (value.directory or (value.session and value.session.directory))
  if directory and require("opencode.runtime.root").realpath(directory) ~= client.root then
    return require("opencode.promise").reject({ error_class = "root_mismatch", endpoint = "/session" })
  end
  return require("opencode.promise").resolve(value)
end

function Client:get_session(id)
  return self:request("GET", "/session/" .. id):next(function(value)
    return verify_session_root(self, value)
  end)
end
function Client:messages(id)
  return self:request("GET", "/session/" .. id .. "/message"):next(function(value)
    return verify_session_root(self, value)
  end)
end
function Client:message(id, message_id)
  return self:request("GET", "/session/" .. id .. "/message/" .. message_id)
end
function Client:prompt_async(id, body)
  return self:request("POST", "/session/" .. id .. "/prompt_async", body)
end
function Client:abort(id)
  return self:request("POST", "/session/" .. id .. "/abort")
end
function Client:questions()
  return self:request("GET", "/question")
end
function Client:question_reply(id, answers)
  return self:request("POST", "/question/" .. id .. "/reply", { answers = answers })
end
function Client:question_reject(id)
  return self:request("POST", "/question/" .. id .. "/reject")
end
function Client:permissions()
  return self:request("GET", "/permission")
end
function Client:permission_reply(id, response)
  return self:request("POST", "/permission/" .. id .. "/reply", { reply = response })
end

---Subscribes to SSE and emits decoded data frames until the stream ends or stops producing heartbeat activity.
---A guarded client timer resets on every output chunk; decode failures and silence stop curl and use the normal exit callback so Runtime recovery stays in one place.
---Curl still has no total transfer timeout because a healthy SSE stream is long-lived.
---@param callback fun(event: table)
---@param on_exit fun(code: integer, error_class?: string)
---@param opts? { connect_timeout_ms?: integer, liveness_timeout_ms?: integer }
---@return integer
function Client:subscribe(callback, on_exit, opts)
  on_exit = on_exit or function() end
  opts = opts or {}
  local connect_timeout = math.max(1, opts.connect_timeout_ms or 10000) / 1000
  local liveness_timeout = math.max(1, opts.liveness_timeout_ms or 30000)
  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--fail",
    "--no-buffer",
    "--connect-timeout",
    string.format("%.3f", connect_timeout),
    "--config",
    "-",
    "-H",
    "Accept: text/event-stream",
    "-H",
    "x-opencode-directory: " .. self.root,
    self.url .. "/event",
  }
  local lines = {}
  if self.closed then
    return 0
  end
  self.stream_generation = self.stream_generation + 1
  if self.stream_timer then
    pcall(self.stream_timer.stop, self.stream_timer)
    local ok, closing = pcall(self.stream_timer.is_closing, self.stream_timer)
    if not ok or not closing then
      pcall(self.stream_timer.close, self.stream_timer)
    end
    self.stream_timer = nil
  end
  if self.stream_job then
    pcall(vim.fn.jobstop, self.stream_job)
    self.stream_job = nil
  end
  local generation = self.stream_generation
  local timer_generation = 0
  local exited = false
  local job
  local function stop_timer()
    timer_generation = timer_generation + 1
    local timer = self.stream_timer
    if not timer then
      return
    end
    self.stream_timer = nil
    pcall(timer.stop, timer)
    local ok, closing = pcall(timer.is_closing, timer)
    if not ok or not closing then
      pcall(timer.close, timer)
    end
  end
  local function same_generation()
    return not self.closed and self.stream_generation == generation
  end
  local function current()
    return not exited and same_generation()
  end
  local function finish(code, error_class, stop_job)
    if not current() then
      return
    end
    exited = true
    stop_timer()
    if self.stream_job == job then
      self.stream_job = nil
    end
    if stop_job and job and job > 0 then
      vim.fn.jobstop(job)
    end
    vim.schedule(function()
      if same_generation() then
        on_exit(code, error_class)
      end
    end)
  end
  local function reset_timer()
    stop_timer()
    if not current() then
      return
    end
    local deadline_generation = timer_generation
    self.stream_timer = vim.defer_fn(function()
      if current() and timer_generation == deadline_generation then
        finish(28, "timeout", true)
      end
    end, liveness_timeout)
  end
  job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not current() then
        return
      end
      if data and #data > 0 then
        reset_timer()
      end
      for _, line in ipairs(data or {}) do
        if line == "" then
          local chunks = {}
          for _, frame_line in ipairs(lines) do
            local value = frame_line:match("^data:%s?(.*)$")
            if value then
              table.insert(chunks, value)
            end
          end
          lines = {}
          if #chunks > 0 then
            local ok, event = pcall(vim.json.decode, table.concat(chunks, "\n"))
            if ok then
              vim.schedule(function()
                if same_generation() then
                  callback(event)
                end
              end)
            else
              finish(1, "decode", true)
              return
            end
          end
        else
          table.insert(lines, line)
        end
      end
    end,
    on_exit = function(_, code)
      finish(code, code == 28 and "timeout" or nil, false)
    end,
  })
  if job > 0 then
    self.stream_job = job
    local sent = vim.fn.chansend(job, curl_config(self.username, self.password))
    if sent <= 0 then
      exited = true
      stop_timer()
      self.stream_job = nil
      vim.fn.jobstop(job)
      return 0
    end
    local closed = pcall(vim.fn.chanclose, job, "stdin")
    if not closed then
      exited = true
      stop_timer()
      self.stream_job = nil
      vim.fn.jobstop(job)
      return 0
    end
    reset_timer()
  end
  return job
end

return Client
