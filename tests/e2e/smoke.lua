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
local interactions = { question = 0, permission = 0 }
vim.ui.select = function(items, _, callback)
  local choice = items[1]
  if type(choice) == "table" then
    interactions.question = interactions.question + 1
  elseif choice == "once" then
    interactions.permission = interactions.permission + 1
  end
  vim.schedule(function()
    callback(choice)
  end)
end
local job, dispatch_error, dispatch_done
require("opencode.api.prompt")
  .prompt(
    "Ask one yes/no question with the question tool, then fetch https://example.com, then try to change return 1 to return 9.",
    context,
    { mode = "plan" }
  )
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
    return require("opencode.job").terminal(job.state)
  end),
  "Plan completion timed out"
)
assert(
  job.state == "completed",
  vim.inspect({
    state = job.state,
    error_class = job.error_class,
    endpoint = job.error_endpoint,
    status = job.error_status,
  })
)
assert(interactions.question > 0, "Plan did not exercise the question workflow")
assert(interactions.permission > 0, "Plan did not exercise an approvable permission")

local messages, messages_error
runtime.client
  :messages(job.session_id)
  :next(function(value)
    messages = value
  end)
  :catch(function(err)
    messages_error = err
  end)
assert(vim.wait(5000, function()
  return messages or messages_error
end), "Plan messages timed out")
assert(messages, vim.inspect(messages_error))
local prohibited_tool_call = false
local tool_states = {}
for _, message in ipairs(messages) do
  local info = message.info or message
  if info.role == "assistant" then
    for _, part in ipairs(message.parts or {}) do
      local state = type(part.state) == "table" and part.state.status or part.state
      if part.type == "tool" then
        table.insert(tool_states, { tool = part.tool, state = state })
      end
      if part.type == "tool" and ({ edit = true, write = true, apply_patch = true })[part.tool] then
        prohibited_tool_call = true
        break
      end
    end
  end
end
assert(not prohibited_tool_call, "Plan exposed a prohibited source-write tool: " .. vim.inspect(tool_states))

local selected, select_error
require("opencode.session")
  .select(runtime, job.session_id)
  :next(function()
    selected = true
  end)
  :catch(function(err)
    select_error = err
  end)
assert(
  vim.wait(5000, function()
    return selected or select_error
  end),
  "Session selection timed out"
)
assert(selected, vim.inspect(select_error))

local old_state, old_message = job.state, job.user_message_id
local build, build_error, build_done
require("opencode.api.prompt")
    .prompt("Change only alpha's return value from 1 to 2 and return the required structured replacement.", context, {
      mode = "build",
  })
  :next(function(value)
    build, build_done = value, true
  end)
  :catch(function(err)
    build_error, build_done = err, true
  end)
assert(
  vim.wait(15000, function()
    return build_done
  end),
  "Build dispatch timed out"
)
assert(build, vim.inspect({ error = build_error, diagnostics = require("opencode.session").diagnostics(runtime) }))
assert(build.session_id == job.session_id, "Build did not reuse the Plan Session")
assert(build.user_message_id ~= old_message, "Build reused the Plan message identity")
assert(job.state == old_state, "Build mutated Plan history")
assert(
  vim.wait(120000, function()
    return require("opencode.job").terminal(build.state)
  end),
  vim.inspect({
    state = build.state,
    late = build.late_event_count,
    remote_idle = build.remote_idle,
    diagnostics = require("opencode.session").diagnostics(runtime),
  })
)
assert(
  build.state == "completed",
  vim.inspect({
    state = build.state,
    error_class = build.error_class,
    endpoint = build.error_endpoint,
    status = build.error_status,
    assistant_ids = vim.tbl_keys(build.assistant_message_ids or {}),
    assistant_messages = vim.tbl_map(function(message)
      return {
        id = message.info and message.info.id,
        parent_id = message.info and message.info.parentID,
        structured = type(message.info and message.info.structured) == "table",
      }
    end, vim.tbl_values(build.assistant_messages or {})),
    correlation = runtime.correlation,
  })
)
assert(
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("return 2", 1, true),
  "Build was not applied"
)

local after = vim.fn.sha256(table.concat(vim.fn.readfile(target, "b"), "\n"))
assert(after == before, "Plan changed the source fixture")
runtime:stop()
vim.cmd("qa!")
