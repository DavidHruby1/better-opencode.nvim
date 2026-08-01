local scenarios = {}

local profiles = { "1.17.3", "1.18.9" }
local unit = "MINI_TEST_PATH=$MINI_TEST_PATH nvim --headless -u tests/minimal_init.lua"

local function acceptance_test(id)
  if id == "AC-UI-05" then
    return "tests/integration/test_request_status.lua"
  end
  if id == "AC-EVT-06" then
    return "tests/contract/test_reasoning_events.lua"
  end
  if id:match("^AC%-RUN%-") or id == "AC-EVT-05" then
    return "tests/release/ac/test_runtime.lua"
  end
  if
    id:match("^AC%-UI%-")
    or id:match("^AC%-CTX%-")
    or id:match("^AC%-MODE%-")
    or id == "AC-SCOPE-01"
    or id == "AC-SCOPE-02"
  then
    return "tests/release/ac/test_ui_context.lua"
  end
  if id:match("^AC%-SCOPE%-") or id:match("^AC%-PROP%-") or id:match("^AC%-MERGE%-") or id == "AC-JOB-03" then
    return "tests/release/ac/test_merge.lua"
  end
  if id:match("^AC%-JOB%-") or id:match("^AC%-EVT%-") or id:match("^AC%-INT%-") or id:match("^AC%-STATE%-") then
    return "tests/release/ac/test_jobs.lua"
  end
  if id == "AC-SEC-02" then
    return "tests/release/ac/test_security.lua"
  end
  return "tests/release/privacy.lua"
end

local function add(id, priority, owner, test, protocol)
  local test_path = acceptance_test(id)
  if id == "AC-SEC-01" then
    test = "nvim --headless -u NONE --cmd 'set runtimepath^=.' -c 'luafile " .. test_path .. "' -c 'qa!'"
  else
    test = unit .. " -c \"lua MiniTest.run_file('" .. test_path .. "')\""
  end
  table.insert(scenarios, {
    id = id,
    priority = priority,
    owner = owner,
    profiles = profiles,
    test = test,
    protocol = protocol,
  })
end

add("AC-RUN-01", "P0", "F02", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-RUN-02", "P0", "F01", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-RUN-03", "P0", "F01", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-RUN-04", "P1", "F01", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-RUN-05", "P1", "F10", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-RUN-06", "P1", "F10", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-RUN-07", "P0", "F01", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-RUN-08", "P1", "F09", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-RUN-09", "P0", "F01", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-UI-01", "P1", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-UI-02", "P1", "F02", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-UI-03", "P2", "F11", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-UI-04", "P2", "F11", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-UI-05", "P1", "F11", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-CTX-01", "P1", "F02", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-CTX-02", "P1", "F02", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-CTX-03", "P0", "F02", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-CTX-04", "P0", "F02", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-CTX-05", "P1", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-CTX-06", "P1", "F02", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-MODE-01", "P0", "F02", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MODE-02", "P0", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MODE-03", "P1", "F07", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-SCOPE-01", "P0", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-SCOPE-02", "P1", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-SCOPE-03", "P0", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-SCOPE-04", "P0", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-SCOPE-05", "P1", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-SCOPE-06", "P0", "F08", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-PROP-01", "P0", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-PROP-02", "P0", "F03", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-PROP-03", "P0", "F03", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-MERGE-01", "P0", "F04", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-02", "P0", "F04", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-03", "P1", "F04", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-04", "P0", "F04", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-05", "P0", "F04", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-06", "P0", "F05", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-07", "P1", "F05", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-08", "P0", "F04", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-09", "P0", "F05", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-10", "P1", "F04", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-11", "P0", "F05", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-MERGE-12", "P0", "F04", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-JOB-01", "P0", "F07", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-JOB-02", "P1", "F07", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-JOB-03", "P0", "F08", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-JOB-04", "P0", "F08", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-JOB-05", "P1", "F10", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-JOB-06", "P0", "F07", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-JOB-07", "P0", "F07", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-EVT-01", "P0", "F07", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-EVT-02", "P0", "F06", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-EVT-03", "P0", "F09", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-EVT-04", "P0", "F09", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-EVT-05", "P1", "F09", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-EVT-06", "P1", "F07", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-INT-01", "P0", "F06", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-INT-02", "P0", "F06", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-INT-03", "P1", "F06", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-INT-04", "P0", "F06", unit .. " -c 'lua MiniTest.run()'", nil)

add("AC-STATE-01", "P0", "F06", unit .. " -c 'lua MiniTest.run()'", nil)
add("AC-STATE-02", "P1", "F07", unit .. " -c 'lua MiniTest.run()'", nil)

add(
  "AC-SEC-01",
  "P0",
  "F11",
  "nvim --headless -u NONE --cmd 'set runtimepath^=.' -c 'luafile tests/release/privacy.lua' -c 'qa!'",
  nil
)
add("AC-SEC-02", "P2", "F11", unit .. " -c 'lua MiniTest.run()'", nil)

return {
  version = 1,
  profiles = profiles,
  scenarios = scenarios,
}
