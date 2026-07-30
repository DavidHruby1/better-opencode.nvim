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
  local runner, calls = require("tests.helpers.fake_opencode").runner({ { body = { healthy = true } } })
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
  eq(argv:find("u:p", 1, true) ~= nil, true)
end

T["source contract freezes permission surface filtering"] = function()
  local source = table.concat(vim.fn.readfile("tests/fixtures/opencode-source-contract.txt"), "\n")
  eq(select(2, source:gsub("Permission%.disabled", "")), 2)
  eq(source:find("edit write apply_patch %-> edit") ~= nil, true)
  eq(source:find("read_mcp_resource %-> read") ~= nil, true)
end

return T
