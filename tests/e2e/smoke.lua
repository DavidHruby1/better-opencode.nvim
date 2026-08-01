local target = vim.fn.fnamemodify("tests/fixtures/e2e.lua", ":p")
local before = vim.fn.sha256(table.concat(vim.fn.readfile(target, "b"), "\n"))
require("snacks").setup({ input = { enabled = true }, picker = { enabled = true } })
vim.cmd.edit(target)

local capture = assert(require("opencode.context").capture())
local runtime, readiness = require("opencode.runtime").acquire(capture)
assert(runtime, "Runtime acquisition failed")
local startup_error, startup_done
readiness
  :next(function()
    startup_done = true
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
assert(startup_error == nil, vim.inspect(startup_error))
assert(runtime.profile.version == vim.env.OPENCODE_VERSION)

local function termcodes(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

---Submits the public ask editor through its real Enter mapping after adding a deterministic second line.
---The returned text proves that multiline editing completed before the public workflow dispatched the Job.
---@param default string
---@param opts table
---@return string
local function ask_with_editor(default, opts)
  local flow = require("opencode").ask(default, opts)
  local early_error
  flow:catch(function(err)
    early_error = err
  end)
  local prompt_win, prompt_buf
  assert(
    vim.wait(5000, function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "opencode_ask" then
          prompt_win, prompt_buf = win, buf
          return true
        end
      end
      return early_error ~= nil
    end),
    "multiline prompt did not open"
  )
  assert(prompt_win, "multiline prompt failed before opening: " .. vim.inspect(early_error))
  vim.api.nvim_set_current_win(prompt_win)
  vim.api.nvim_buf_set_lines(prompt_buf, -1, -1, false, { "Keep this request multiline." })
  assert(
    vim.wait(1000, function()
      return vim.api.nvim_buf_line_count(prompt_buf) >= 2
    end),
    "multiline editor did not create a second line"
  )
  vim.cmd.startinsert()
  vim.api.nvim_feedkeys(termcodes("<CR>"), "mtx", false)

  local value, error
  flow
    :next(function(result)
      value = result
    end)
    :catch(function(err)
      error = err
    end)
  assert(
    vim.wait(15000, function()
      return value ~= nil or error ~= nil
    end),
    "public ask did not submit"
  )
  assert(error == nil, vim.inspect(error))
  assert(value:find("Keep this request multiline.", 1, true) ~= nil, "multiline text was not submitted")
  return value
end

local function current_job()
  local session = runtime.sessions[runtime.selected_session_id]
  assert(session and session.active_job_key, "public ask did not select its Session")
  return runtime.jobs[session.active_job_key]
end

local interactions = { question = 0, permission = 0 }
local old_select = vim.ui.select
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

local plan_text = ask_with_editor(
  "Ask one yes/no question with the question tool, then fetch https://example.com, then try to change return 1 to return 9.",
  { mode = "plan" }
)
assert(plan_text:find("question tool", 1, true) ~= nil)
local plan = current_job()
assert(
  vim.wait(120000, function()
    return require("opencode.job").terminal(plan.state)
  end),
  "Plan completion timed out"
)
assert(plan.state == "completed", vim.inspect({ state = plan.state, error_class = plan.error_class }))
assert(interactions.question > 0, "Plan did not exercise the question workflow")
assert(interactions.permission > 0, "Plan did not exercise an approvable permission")

local messages, messages_error
runtime.client
  :messages(plan.session_id)
  :next(function(value)
    messages = value
  end)
  :catch(function(err)
    messages_error = err
  end)
assert(
  vim.wait(5000, function()
    return messages or messages_error
  end),
  "Plan messages timed out"
)
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

local plan_session_id, plan_state = plan.session_id, plan.state
local build_text = ask_with_editor(
  "Change only alpha's return value from 1 to 2 and return the required structured replacement.",
  { mode = "build" }
)
assert(build_text:find("structured replacement", 1, true) ~= nil)
local build = current_job()
assert(build.session_id == plan_session_id, "Build did not reuse the Plan Session")
assert(build.user_message_id ~= plan.user_message_id, "Build reused the Plan message identity")
assert(plan.state == plan_state, "Build mutated Plan history")
local build_finished = vim.wait(120000, function()
  return require("opencode.job").terminal(build.state)
end)
if not build_finished then
  local remote_messages, remote_error
  runtime.client
    :messages(build.session_id)
    :next(function(value)
      remote_messages = value
    end)
    :catch(function(err)
      remote_error = err
    end)
  vim.wait(5000, function()
    return remote_messages ~= nil or remote_error ~= nil
  end)
  local summary = {}
  for _, message in ipairs(remote_messages or {}) do
    local info = message.info or message
    local parts = {}
    for _, part in ipairs(message.parts or {}) do
      table.insert(parts, {
        type = part.type,
        tool = part.tool,
        status = type(part.state) == "table" and part.state.status or part.state,
      })
    end
    table.insert(summary, {
      role = info.role,
      finish = info.finish,
      error = type(info.error) == "table" and info.error.name or nil,
      structured = type(info.structured) == "table",
      parts = parts,
    })
  end
  error(vim.inspect({
    state = build.state,
    diagnostics = require("opencode.session").diagnostics(runtime),
    remote_error = remote_error,
    messages = summary,
  }))
end
assert(
  build.state == "completed",
  vim.inspect({
    state = build.state,
    error_class = build.error_class,
    assistant_ids = vim.tbl_keys(build.assistant_message_ids or {}),
    correlation = runtime.correlation,
  })
)
assert(
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("return 2", 1, true),
  "Build was not applied"
)

local after = vim.fn.sha256(table.concat(vim.fn.readfile(target, "b"), "\n"))
assert(after == before, "Plan or Build changed the source fixture on disk")
vim.ui.select = old_select
runtime:stop()
vim.cmd("qa!")
