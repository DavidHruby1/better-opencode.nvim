local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["root containment is component safe"] = function()
  local root = require("opencode.runtime.root")
  eq(root.contains("/tmp/app", "/tmp/app/a"), true)
  eq(root.contains("/tmp/app", "/tmp/application"), false)
end

T["JSONC preserves comment-like strings"] = function()
  local guard = require("opencode.runtime.config_guard")
  local value = assert(guard.decode([[{"url":"https://x/y",/* c */"mcp":{"x":{"enabled":false}},}]]))
  eq(value.url, "https://x/y")
  eq(guard.validate(value), true)
end

T["config rejects executable extensions"] = function()
  local guard = require("opencode.runtime.config_guard")
  eq(select(2, guard.validate({ plugin = { "x" } })), "custom_plugin")
  eq(select(2, guard.validate({ mcp = { x = { enabled = true } } })), "enabled_mcp")
end

T["message IDs and Job keys are OpenCode compatible"] = function()
  local job = require("opencode.job").new("ses_1", { root = "/r", buf = 1, path = "/r/a" })
  eq(job.user_message_id:match("^msg_[0-9A-HJKMNP-TV-Z]+$") ~= nil, true)
  eq(job.key, "ses_1:" .. job.user_message_id)
end

T["permission profile keeps hard denies last"] = function()
  local rules = require("opencode.session").permissions
  eq(rules[#rules - 3].permission, "edit")
  eq(rules[#rules].permission, "external_directory")
  eq(require("opencode.session").verify_permissions(rules), true)
end

T["Session errors terminate the correlated Plan once"] = function()
  local runtime = require("opencode.runtime").new("/root")
  local session = { id = "ses_1", active_job_key = "ses_1:msg_1" }
  local job = { key = session.active_job_key, state = "running" }
  runtime.sessions[session.id] = session
  runtime.jobs[job.key] = job
  runtime:route_event({ type = "session.error", properties = { sessionID = session.id } })
  eq(job.state, "error")
  runtime:route_event({ type = "session.error", properties = { sessionID = session.id } })
  eq(job.state, "error")
end

T["byte coordinates round trip only at UTF-8 boundaries"] = function()
  local snapshot = require("opencode.snapshot")
  local text = "až\n中b"
  for _, offset in ipairs({ 0, 1, 3, 4, 7, 8 }) do
    local row, col = snapshot.offset_to_position(text, offset)
    eq(snapshot.position_to_offset(text, row, col), offset)
  end
  eq(select(2, snapshot.offset_to_position(text, 2)), "mid_codepoint")
  eq(select(2, snapshot.position_to_offset(text, 0, 2)), "mid_codepoint")
end

T["disk decoding preserves empty and trailing logical lines"] = function()
  local snapshot = require("opencode.snapshot")
  eq(snapshot.decode_disk("", { fileformat = "unix", endofline = false }), "")
  eq(snapshot.decode_disk("\n", { fileformat = "unix", endofline = true }), "")
  eq(snapshot.decode_disk("a\n\n", { fileformat = "unix", endofline = true }), "a\n")
  eq(snapshot.decode_disk("a\r\n", { fileformat = "dos", endofline = true }), "a")
  eq(select(2, snapshot.decode_disk("a\r\nb\n", { fileformat = "dos", endofline = true })), "mixed_eol")
end

T["visual ranges are half-open and blockwise is rejected"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc", "def" })
  local context =
    { buf = buf, path = "/r/a", cursor = { 1, 0 }, range = { from = { 1, 1 }, to = { 1, 1 }, kind = "char" } }
  local scope = require("opencode.scope").resolve(context, { text = "abc\ndef" })
  eq({ scope.start_byte, scope.end_byte }, { 1, 2 })
  context.range.kind = "line"
  context.range.from, context.range.to = { 1, 0 }, { 1, 2 }
  scope = require("opencode.scope").resolve(context, { text = "abc\ndef" })
  eq({ scope.start_byte, scope.end_byte }, { 0, 4 })
  context.range.kind = "block"
  eq(select(2, require("opencode.scope").resolve(context, { text = "abc\ndef" })), "blockwise_selection")
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["overlap excludes touching half-open ranges"] = function()
  local overlaps = require("opencode.scope").overlaps
  eq(overlaps({ start_byte = 0, end_byte = 3 }, { start_byte = 2, end_byte = 4 }), true)
  eq(overlaps({ start_byte = 0, end_byte = 3 }, { start_byte = 3, end_byte = 4 }), false)
end

T["proposal schema and identity construct exact Theirs"] = function()
  local base = "one\ntwo\nthree"
  local job = {
    root = "/root",
    path = "/root/a.lua",
    base = { text = base, sha256 = vim.fn.sha256(base) },
    scope = { start_byte = 4, end_byte = 7 },
  }
  local value = {
    version = 1,
    path = "a.lua",
    base_sha256 = job.base.sha256,
    scope = { start_byte = 4, end_byte = 7 },
    replacement = "TWO",
    summary = "change",
  }
  local validated = require("opencode.proposal").validate(value, job)
  eq(validated.theirs, "one\nTWO\nthree")
  value.scope.end_byte = 8
  eq(select(2, require("opencode.proposal").validate(value, job)).error_class, "scope_violation")
  value.scope.end_byte, value.replacement = 7, "bad\rtext"
  eq(select(2, require("opencode.proposal").validate(value, job)).error_class, "invalid_structured_output")
end

T["changed span is minimal and UTF-8 safe"] = function()
  local span = require("opencode.apply").changed_span("ažc", "a中c")
  eq(span.start_byte, 1)
  eq(span.ours_end, 3)
  eq(span.replacement, "中")
end

T["merge backend reports clean, conflict, and process failure"] = function()
  local merge = require("opencode.merge")
  local results = {}
  merge.run("a\nb", "A\nb", "a\nB"):next(function(value)
    results.clean = value
  end)
  merge.run("a", "ours", "theirs"):next(function(value)
    results.conflict = value
  end)
  merge
    .run("a", "b", "c", {
      runner = function(_, _, callback)
        callback({ code = -1, signal = 9 })
      end,
    })
    :catch(function(err)
      results.error = err
    end)
  eq(
    vim.wait(1000, function()
      return results.clean and results.conflict and results.error
    end),
    true
  )
  eq(results.clean, { kind = "clean", text = "A\nB" })
  eq(results.conflict.kind, "conflict")
  eq(results.error.error_class, "merge_process")
end

return T
