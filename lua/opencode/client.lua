local Client = {}
Client.__index = Client

---Creates a root-routed authenticated OpenCode client.
---@param opts { host: string, port: integer, username: string, password: string, root: string, runner?: function }
---@return table
function Client.new(opts)
  local self = setmetatable({
    host = opts.host,
    port = opts.port,
    username = opts.username,
    password = opts.password,
    root = opts.root,
    runner = opts.runner or vim.system,
    url = "",
  }, Client)
  self.url = string.format("http://%s:%d", self.host, self.port)
  return self
end

local function request_error(endpoint, code, status)
  return { error_class = code == 124 and "timeout" or "http", endpoint = endpoint, status = status }
end

---Sends one JSON request with mandatory authentication and root routing.
---Only status metadata escapes on failure; response bodies are never included in errors or logs.
---@param method string
---@param endpoint string
---@param body? table
---@return Promise<any>
function Client:request(method, endpoint, body)
  local Promise = require("opencode.promise")
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
      "--user",
      self.username .. ":" .. self.password,
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
    if body then
      vim.list_extend(cmd, { "--data-binary", vim.json.encode(body) })
    end
    table.insert(cmd, self.url .. endpoint)
    self.runner(cmd, { text = true }, function(result)
      vim.schedule(function()
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
    end)
  end)
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
function Client:update_session(id, body)
  return self:request("PATCH", "/session/" .. id, body)
end
function Client:get_session(id)
  return self:request("GET", "/session/" .. id)
end
function Client:messages(id)
  return self:request("GET", "/session/" .. id .. "/message")
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

---Subscribes to SSE and emits decoded data frames.
---Frames are separated by blank lines and may contain multiple data lines.
---@param callback fun(event: table)
---@param on_exit fun(code: integer)
---@return integer
function Client:subscribe(callback, on_exit)
  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--no-buffer",
    "--user",
    self.username .. ":" .. self.password,
    "-H",
    "Accept: text/event-stream",
    "-H",
    "x-opencode-directory: " .. self.root,
    self.url .. "/event",
  }
  local lines = {}
  return vim.fn.jobstart(cmd, {
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
end

return Client
