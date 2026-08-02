---@diagnostic disable: duplicate-set-field

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

---Submits the public ask editor through real Ctrl-j and Enter mappings after adding a deterministic second line.
---The returned text proves that multiline editing completed before the public workflow dispatched the Job.
---@param default string
---@param opts table
---@param trigger? fun(): Promise<string>
---@param cancel? boolean
---@return string
local function ask_with_editor(default, opts, trigger, cancel)
  local flow = assert(trigger and trigger() or require("opencode").ask(default, opts))
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
  if default and vim.api.nvim_buf_line_count(prompt_buf) == 1 then
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { default })
    vim.api.nvim_win_set_cursor(prompt_win, { 1, #default })
  end
  vim.cmd.startinsert()
  vim.api.nvim_feedkeys(termcodes("<C-j>"), "mtx", false)
  assert(
    vim.wait(1000, function()
      return vim.api.nvim_buf_line_count(prompt_buf) >= 2
    end),
    "Ctrl-j did not create a second line"
  )
  vim.api.nvim_feedkeys(termcodes("Keep this request multiline."), "mtx", false)
  assert(
    vim.wait(1000, function()
      return table
        .concat(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), "\n")
        :find("Keep this request multiline.", 1, true) ~= nil
    end),
    "multiline editor did not accept the second line"
  )
  if cancel then
    vim.api.nvim_feedkeys(termcodes("<Esc>"), "mtx", false)
    local _, error
    flow:catch(function(err)
      error = err
    end)
    assert(
      vim.wait(5000, function()
        return error ~= nil
      end),
      "mapped prompt did not cancel"
    )
    assert(error.error_class == "cancelled", vim.inspect(error))
    return ""
  end
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

local source_win = vim.api.nvim_get_current_win()
local mapped_flow
vim.keymap.set({ "n", "x" }, "<C-a>", function()
  mapped_flow = require("opencode").ask(nil, { mode = "build", new_session = true })
end, { silent = true })

---Invokes the documented new-Session Build mapping in normal or visual mode and returns its public flow.
---@param visual boolean
---@return Promise<string>
local function mapped_build(visual)
  mapped_flow = nil
  if visual then
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    vim.cmd("normal! v")
  else
    vim.cmd("normal! <Esc>")
  end
  vim.api.nvim_feedkeys(termcodes("<C-a>"), "mtx", false)
  assert(
    vim.wait(5000, function()
      return mapped_flow ~= nil
    end),
    visual and "visual Build mapping did not invoke ask" or "normal Build mapping did not invoke ask"
  )
  return mapped_flow
end

ask_with_editor("Cancel this visual Build mapping.", { mode = "build", new_session = true }, function()
  return mapped_build(true)
end, true)

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

local first_build_text = ask_with_editor(
  "Inspect the current function, ask one yes/no question if needed, and return the required structured replacement.",
  { mode = "build", new_session = true }
)
assert(first_build_text:find("structured replacement", 1, true) ~= nil)
assert(vim.api.nvim_get_current_win() == source_win, "Build changed Neovim source focus")
local first_build = current_job()
assert(first_build.mode == "build", "first request did not use Build")
assert(runtime.tui_live == nil and runtime.tui_status == nil and runtime.sidebar == nil, "Build started a TUI")
assert(runtime.selected_session_id == first_build.session_id, "Build did not select its Session")
assert(
  vim.wait(120000, function()
    return require("opencode.job").terminal(first_build.state)
  end),
  "Build completion timed out"
)
assert(
  first_build.state == "completed",
  vim.inspect({ state = first_build.state, error_class = first_build.error_class })
)

local messages, messages_error
runtime.client
  :messages(first_build.session_id)
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
  "Build messages timed out"
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
assert(not prohibited_tool_call, "Build exposed a prohibited source-write tool: " .. vim.inspect(tool_states))

local first_session_id, first_state = first_build.session_id, first_build.state
local build_reuse_text =
  ask_with_editor("Inspect this Build result and return a concise follow-up.", { mode = "build" })
assert(build_reuse_text:find("follow-up", 1, true) ~= nil)
assert(vim.api.nvim_get_current_win() == source_win, "reused Build changed Neovim source focus")
local reused_build = current_job()
assert(reused_build.session_id == first_session_id, "Build did not reuse its Session")
assert(runtime.sidebar == nil, "reused Build created a TUI")
assert(reused_build.user_message_id ~= first_build.user_message_id, "Build reused the message identity")
local reused_build_finished = vim.wait(120000, function()
  return require("opencode.job").terminal(reused_build.state)
end)
assert(
  reused_build_finished and reused_build.state == "completed",
  vim.inspect({
    state = reused_build.state,
    error_class = reused_build.error_class,
  })
)

local build_text = ask_with_editor(
  "Change only alpha's return value from 1 to 2 and return the required structured replacement.",
  { mode = "build", new_session = true },
  function()
    return mapped_build(false)
  end
)
assert(build_text:find("structured replacement", 1, true) ~= nil)
assert(vim.api.nvim_get_current_win() == source_win, "Build changed Neovim source focus")
local build = current_job()
assert(build.session_id ~= first_session_id, "new Build mapping reused the selected Session")
assert(build.user_message_id ~= first_build.user_message_id, "Build reused the previous message identity")
assert(first_build.state == first_state, "new Build mapping mutated the previous history")
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
assert(after == before, "Build changed the source fixture on disk")
vim.ui.select = old_select
runtime:stop()
vim.cmd("qa!")
