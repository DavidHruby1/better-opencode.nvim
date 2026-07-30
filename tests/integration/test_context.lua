local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["active location is injected exactly once"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "local x = 1" }, path)
  vim.cmd.edit(path)
  local capture = assert(require("opencode.context").capture())
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  local rendered = context:render("Explain @this").plaintext
  local location = require("opencode.context.builtins").this(context)
  local _, count = rendered:gsub(vim.pesc(location), "")
  eq(count, 1)
  vim.uv.fs_unlink(path)
end

T["unsupported unnamed buffer fails before Runtime"] = function()
  vim.cmd.enew()
  eq(select(2, require("opencode.context").capture()), "unnamed_buffer")
end

T["extmark scope tracks insertion with configured gravity"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta" })
  local scope = { start_byte = 6, end_byte = 10 }
  local marks = require("opencode.scope").create_marks(buf, scope)
  local job = { buffer = buf, marks = marks }
  vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "prefix", "" })
  local current = require("opencode.scope").current_range(job)
  eq({ current.start_byte, current.end_byte }, { 13, 17 })
  require("opencode.scope").delete_marks(job)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["clean merge applies once without writing disk and one undo restores Ours"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "one", "two", "three" }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  local base = assert(require("opencode.snapshot").capture(buf))
  local scope = { kind = "range", path = path, start_byte = 4, end_byte = 7 }
  local marks = require("opencode.scope").create_marks(buf, scope)
  local session = { id = "ses_apply", active_job_key = "job" }
  local job = {
    key = "job",
    session_id = session.id,
    mode = "build",
    state = "pending_apply",
    buffer = buf,
    path = path,
    base = base,
    scope = scope,
    marks = marks,
    theirs = "one\nTWO\nthree",
  }
  local runtime = { sessions = { [session.id] = session }, jobs = { [job.key] = job } }
  require("opencode.apply").start(job, runtime)
  eq(
    vim.wait(1000, function()
      return job.state ~= "pending_apply"
    end),
    true
  )
  eq(job.state, "completed")
  eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), job.theirs or "one\nTWO\nthree")
  eq(table.concat(vim.fn.readfile(path), "\n"), "one\ntwo\nthree")
  eq(vim.bo[buf].modified, true)
  vim.cmd.undo()
  eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "one\ntwo\nthree")
  vim.cmd.bwipeout({ bang = true })
  vim.uv.fs_unlink(path)
end

return T
