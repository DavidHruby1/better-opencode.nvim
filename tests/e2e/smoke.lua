local target = vim.fn.fnamemodify("tests/fixtures/e2e.lua", ":p")
local before = vim.fn.sha256(table.concat(vim.fn.readfile(target, "b"), "\n"))
vim.cmd.edit(target)

local capture = assert(require("opencode.context").capture())
local runtime, startup_error, startup_done
require("opencode.runtime")
  .get_or_start(capture)
  :next(function(value)
    runtime, startup_done = value, true
  end)
  :catch(function(err)
    startup_error, startup_done = err, true
  end)
assert(
  vim.wait(15000, function()
    return startup_done
  end),
  "Runtime startup timed out"
)
assert(runtime, vim.inspect(startup_error))
assert(runtime.profile.version == vim.env.OPENCODE_VERSION)

local context = require("opencode.context").new(capture, runtime)
local job, dispatch_error, dispatch_done
require("opencode.api.prompt")
  .prompt("Read @this and explain what the function returns. Do not modify any file.", context)
  :next(function(value)
    job, dispatch_done = value, true
  end)
  :catch(function(err)
    dispatch_error, dispatch_done = err, true
  end)
assert(
  vim.wait(15000, function()
    return dispatch_done
  end),
  "Plan dispatch timed out"
)
assert(job, vim.inspect(dispatch_error))
assert(
  vim.wait(120000, function()
    return job.state ~= "running"
  end),
  "Plan completion timed out"
)
assert(job.state == "completed", "Plan ended in " .. job.state)

local after = vim.fn.sha256(table.concat(vim.fn.readfile(target, "b"), "\n"))
assert(after == before, "Plan changed the source fixture")
runtime:stop()
