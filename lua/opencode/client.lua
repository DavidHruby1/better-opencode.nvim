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
    url = "",
  }, Client)
  self.url = string.format("http://%s:%d", self.host, self.port)
  return self
end

local function request_error(endpoint, code, status)
  return { error_class = code == 124 and "timeout" or "http", endpoint = endpoint, status = status }
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
    local process
    process = self.runner(
      cmd,
      { text = true, stdin = curl_config(self.username, self.password, body) },
      function(result)
        if process then
          self.requests[process] = nil
        end
        if self.closed then
          return
        end
        vim.schedule(function()
          if
            self.runtime
            and (
              self.runtime.generation ~= request_generation
              or self.runtime.state == "stopping"
              or self.runtime.state == "stopped"
            )
          then
            reject({ error_class = "stale_generation", endpoint = endpoint })
            return
          end
          local payload, status = (result.stdout or ""):match("^(.*)__OPENCODE_STATUS__:(%d%d%d)$")
          status = tonumber(status)
          if result.code ~= 0 or not status or status >= 400 then
            reject(request_error(endpoint, result.code, status))
            return
          end
          if status == 204 or payload == "" then
            resolve(nil)
            return
          end
          local ok, decoded = pcall(vim.json.decode, payload)
          if not ok then
            reject({ error_class = "decode", endpoint = endpoint, status = status })
            return
          end
          resolve(decoded)
        end)
      end
    )
    if process then
      self.requests[process] = true
    end
  end)
end

---Cancels all in-flight HTTP transports and prevents late callbacks from resolving Runtime state.
---The runner remains injectable for contract tests; real vim.system handles are killed best-effort.
function Client:cancel_requests()
  self.closed = true
  for process in pairs(self.requests) do
    if process and process.kill then
      pcall(process.kill, process, "sigterm")
    end
  end
  self.requests = {}
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
function Client:select_session(id)
  return self:request("POST", "/tui/select-session", { sessionID = id })
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

---Subscribes to SSE and emits decoded data frames.
---Frames are separated by blank lines and may contain multiple data lines.
---@param callback fun(event: table)
---@param on_exit fun(code: integer)
---@return integer
function Client:subscribe(callback, on_exit)
  on_exit = on_exit or function() end
  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--no-buffer",
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
  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
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
                callback(event)
              end)
            end
          end
        else
          table.insert(lines, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        on_exit(code)
      end)
    end,
  })
  if job > 0 then
    vim.fn.chansend(job, curl_config(self.username, self.password))
    vim.fn.chanclose(job, "stdin")
  end
  return job
end

return Client
