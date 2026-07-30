local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["both frozen documents expose required operations"] = function()
  for version, profile in pairs(require("opencode.compat")) do
    local doc = vim.json.decode(table.concat(vim.fn.readfile(profile.fixture), "\n"))
    local ok, missing = require("opencode.runtime").verify_doc(doc, profile)
    eq(ok, true, version .. ": " .. tostring(missing))
  end
end

T["client always sends auth and canonical root header"] = function()
  local runner, calls, options = require("tests.helpers.fake_opencode").runner({ { body = { healthy = true } } })
  local client = require("opencode.client").new({
    host = "127.0.0.1",
    port = 1,
    username = "u",
    password = "p",
    root = "/canonical",
    runner = runner,
  })
  local result
  client:health():next(function(value)
    result = value
  end)
  vim.wait(100, function()
    return result ~= nil
  end)
  local argv = table.concat(calls[1], "\0")
  eq(argv:find("x%-opencode%-directory: /canonical") ~= nil, true)
  eq(argv:find("u:p", 1, true), nil)
  eq(options[1].stdin:find('user = "u:p"', 1, true) ~= nil, true)
end

T["source contract freezes permission surface filtering"] = function()
  local source = table.concat(vim.fn.readfile("tests/fixtures/opencode-source-contract.txt"), "\n")
  eq(select(2, source:gsub("Permission%.disabled", "")), 2)
  eq(source:find("edit write apply_patch %-> edit") ~= nil, true)
  eq(source:find("read_mcp_resource %-> read") ~= nil, true)
end

T["interaction client uses canonical endpoints and payloads"] = function()
  local runner, calls, options = require("tests.helpers.fake_opencode").runner({ {}, {}, {}, {} })
  local client = require("opencode.client").new({
    host = "127.0.0.1",
    port = 1,
    username = "u",
    password = "p",
    root = "/canonical",
    runner = runner,
  })
  client:question_reply("question-1", { { "answer" } })
  client:question_reject("question-1")
  client:permission_reply("permission-1", "once")
  client:permissions()
  eq(
    vim.wait(100, function()
      return #calls == 4
    end),
    true
  )
  local question = table.concat(calls[1], "\0")
  local rejection = table.concat(calls[2], "\0")
  local permission = table.concat(calls[3], "\0")
  local list = table.concat(calls[4], "\0")
  eq(question:find("/question/question%-1/reply") ~= nil, true)
  eq(question:find("answer", 1, true), nil)
  eq(options[1].stdin:find("answers", 1, true) ~= nil, true)
  eq(options[1].stdin:find("answer", 1, true) ~= nil, true)
  eq(rejection:find("/question/question%-1/reject") ~= nil, true)
  eq(permission:find("/permission/permission%-1/reply") ~= nil, true)
  eq(permission:find("once", 1, true), nil)
  eq(options[3].stdin:find("reply", 1, true) ~= nil, true)
  eq(options[3].stdin:find("once", 1, true) ~= nil, true)
  eq(options[3].stdin:find("response", 1, true), nil)
  eq(list:find("/permission") ~= nil, true)
end

T["both profiles require the canonical permission reply field"] = function()
  local function operation(value, id)
    if type(value) ~= "table" then
      return nil
    end
    if value.operationId == id then
      return value
    end
    for _, child in pairs(value) do
      local found = operation(child, id)
      if found then
        return found
      end
    end
  end
  for version, profile in pairs(require("opencode.compat")) do
    local doc = vim.json.decode(table.concat(vim.fn.readfile(profile.fixture), "\n"))
    local reply = assert(operation(doc, "permission.reply"), version)
    local schema = reply.requestBody.content["application/json"].schema
    eq(schema.required, { "reply" }, version)
    eq(schema.properties.reply.enum, { "once", "always", "reject" }, version)
    eq(schema.properties.response, nil, version)
  end
end

T["Session reuse and cancellation use canonical endpoints"] = function()
  local runner, calls, options = require("tests.helpers.fake_opencode").runner({ {}, {}, {}, {}, {} })
  local client = require("opencode.client").new({
    host = "127.0.0.1",
    port = 1,
    username = "u",
    password = "p",
    root = "/canonical",
    runner = runner,
  })
  client:list_sessions()
  client:session_status()
  client:update_session("ses_1", { permission = { { permission = "*", pattern = "*", action = "deny" } } })
  client:abort("ses_1")
  client:select_session("ses_1")
  eq(vim.wait(100, function()
    return #calls == 5
  end), true)
  eq(table.concat(calls[1], "\0"):find("/session", 1, true) ~= nil, true)
  eq(table.concat(calls[2], "\0"):find("/session/status", 1, true) ~= nil, true)
  eq(table.concat(calls[3], "\0"):find("/session/ses_1", 1, true) ~= nil, true)
  eq(options[3].stdin:find("permission", 1, true) ~= nil, true)
  eq(table.concat(calls[4], "\0"):find("/session/ses_1/abort", 1, true) ~= nil, true)
  eq(table.concat(calls[5], "\0"):find("/tui/select-session", 1, true) ~= nil, true)
  eq(options[5].stdin:find("ses_1", 1, true) ~= nil, true)
end

return T
