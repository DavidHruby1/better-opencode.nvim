local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["root containment is component safe"] = function()
  local root = require("opencode.runtime.root")
  eq(root.contains("/tmp/app", "/tmp/app/a"), true)
  eq(root.contains("/tmp/app", "/tmp/application"), false)
end

T["JSONC preserves comment-like strings"] = function()
  local guard = require("opencode.runtime.config_guard")
  local value = assert(guard.decode([[{"url":"https://x/y","literal":",}",/* c */"mcp":{"x":{"enabled":false}},}]]))
  eq(value.url, "https://x/y")
  eq(value.literal, ",}")
  eq(guard.validate(value), true)
end

T["config rejects executable extensions"] = function()
  local guard = require("opencode.runtime.config_guard")
  eq(select(2, guard.validate({ plugin = { "x" } })), "custom_plugin")
  eq(select(2, guard.validate({ mcp = { x = { enabled = true } } })), "enabled_mcp")
end

T["config guard scans standard global executable directories"] = function()
  local root = vim.fn.tempname()
  local home = root .. "/home"
  local config_home = root .. "/config"
  vim.fn.mkdir(config_home .. "/opencode/plugin", "p")
  vim.fn.mkdir(home, "p")
  vim.fn.writefile({ "return {}" }, config_home .. "/opencode/plugin/unsafe.lua")
  local old_home, old_config = vim.env.HOME, vim.env.XDG_CONFIG_HOME
  vim.env.HOME, vim.env.XDG_CONFIG_HOME = home, config_home
  local ok, reason = require("opencode.runtime.config_guard").scan(root)
  vim.env.HOME, vim.env.XDG_CONFIG_HOME = old_home, old_config
  vim.fn.delete(root, "rf")
  eq({ ok, reason }, { false, "custom_plugin" })
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

T["Session errors terminate only an exactly correlated Plan"] = function()
  local runtime = require("opencode.runtime").new("/root")
  local session = { id = "ses_1", active_job_key = "ses_1:msg_1" }
  local job = { key = session.active_job_key, state = "running", user_message_id = "msg_1" }
  runtime.sessions[session.id] = session
  runtime.jobs[job.key] = job
  runtime:route_event({ type = "session.error", properties = { sessionID = session.id, messageID = "msg_1" } })
  eq(job.state, "error")
  runtime:route_event({ type = "session.error", properties = { sessionID = session.id } })
  eq(job.state, "error")
end

T["managed Session ownership, availability, and short IDs are derived"] = function()
  local sessions = require("opencode.session")
  local runtime = require("opencode.runtime").new("/tmp")
  local owned = {
    id = "ses_12345678same-tail",
    directory = "/tmp",
    metadata = sessions.metadata(runtime.root_hash),
  }
  eq(sessions.managed(owned, runtime, true), true)
  owned.metadata.contract_version = 1
  eq(sessions.managed(owned, runtime, true), false)
  owned.metadata.contract_version = 2
  owned.time = { archived = 1 }
  eq(sessions.managed(owned, runtime, true), false)
  owned.time = nil
  local other = { id = "ses_87654321same-tail" }
  sessions.assign_short_ids({ owned, other })
  eq(owned.short_id ~= other.short_id, true)
  local session = { id = owned.id, active_job_key = "job" }
  runtime.jobs.job = { key = "job", session_id = owned.id, state = "conflict" }
  eq(sessions.availability(runtime, session, "idle"), "active")
  runtime.jobs.job.state, session.active_job_key = "completed", nil
  eq(sessions.availability(runtime, session, "idle"), "reusable")
  eq(sessions.availability(runtime, session, "busy"), "blocked")
  eq({ runtime.prompt_locked, runtime.reconciliation_required }, { true, true })
end

T["assistant routing keeps old turn identity during Session reuse"] = function()
  local runtime = require("opencode.runtime").new("/root")
  local old = require("opencode.job").new("ses_1", { root = "/root", buf = 1, path = "/root/a", mode = "plan" })
  local current = require("opencode.job").new("ses_1", { root = "/root", buf = 1, path = "/root/a", mode = "plan" })
  old.state = "completed"
  runtime.jobs[old.key], runtime.jobs[current.key] = old, current
  runtime.sessions.ses_1 = { id = "ses_1", active_job_key = current.key }
  runtime:route_event({
    type = "message.updated",
    properties = { info = { id = "msg_assistant_old", role = "assistant", sessionID = "ses_1", parentID = old.user_message_id } },
  })
  runtime:route_event({
    type = "message.updated",
    properties = {
      info = { id = "msg_assistant_new", role = "assistant", sessionID = "ses_1", parentID = current.user_message_id },
    },
  })
  runtime:route_event({
    type = "message.part.updated",
    properties = { part = { sessionID = "ses_1", messageID = "msg_assistant_old" } },
  })
  eq(runtime.assistant_jobs["ses_1:msg_assistant_new"], current.key)
  eq(current.late_event_count, nil)
  eq(old.late_event_count, 2)
  eq(current.state, "running")
end

T["part before assistant bootstrap closes the prompt gate"] = function()
  local runtime = require("opencode.runtime").new("/root")
  runtime:route_event({
    type = "message.part.updated",
    properties = { part = { sessionID = "ses_1", messageID = "msg_unknown" } },
  })
  eq({ runtime.prompt_locked, runtime.reconciliation_required, runtime.correlation.unknown }, { true, true, 1 })
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
  eq(snapshot.valid_utf8("až中"), true)
  for _, invalid in ipairs({ string.char(0x80), string.char(0xc0, 0x80), string.char(0xed, 0xa0, 0x80), string.char(0xf4, 0x90, 0x80, 0x80) }) do
    eq(snapshot.valid_utf8(invalid), false)
  end
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
  eq(require("opencode.proposal").schema.properties.version.type, "integer")
  eq(validated.theirs, "one\nTWO\nthree")
  value.scope.end_byte = 8
  eq(select(2, require("opencode.proposal").validate(value, job)).error_class, "scope_violation")
  value.scope.end_byte, value.replacement = 7, "bad\rtext"
  eq(select(2, require("opencode.proposal").validate(value, job)).error_class, "invalid_structured_output")
end

T["user message parts do not enter assistant reconciliation"] = function()
  local runtime = require("opencode.runtime").new("/root")
  local job = require("opencode.job").new("ses_1", { root = "/root", buf = 1, path = "/root/a" })
  runtime.jobs[job.key] = job
  runtime.sessions.ses_1 = { id = "ses_1", active_job_key = job.key }
  runtime:route_event({
    type = "message.part.updated",
    properties = { sessionID = "ses_1", part = { sessionID = "ses_1", messageID = job.user_message_id } },
  })
  eq({ runtime.correlation.exact, runtime.correlation.unknown, runtime.prompt_locked }, { 1, 0, false })
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
  merge
    .run("a", "b", "c", {
      runner = function(_, _, callback)
        callback({ code = 127, signal = 0, stdout = "" })
      end,
    })
    :catch(function(err)
      results.invocation_error = err
    end)
  merge
    .run("a", "b", "c", {
      runner = function(_, _, callback)
        callback({ code = 2, signal = 0, stdout = "not a conflict" })
      end,
    })
    :catch(function(err)
      results.non_conflict_exit = err
    end)
  eq(
    vim.wait(1000, function()
      return results.clean and results.conflict and results.error and results.invocation_error and results.non_conflict_exit
    end),
    true
  )
  eq(results.clean, { kind = "clean", text = "A\nB" })
  eq(results.conflict.kind, "conflict")
  eq(results.error.error_class, "merge_process")
  eq(results.invocation_error.error_class, "merge_process")
  eq(results.non_conflict_exit.error_class, "merge_process")
end

T["Job transition matrix requires kinds and keeps terminal transitions idempotent"] = function()
  local jobs = require("opencode.job")
  local session = { active_job_key = "job" }
  local job = { key = "job", root = "/root", state = "running" }
  eq(jobs.transition(job, "waiting_user", { session = session }), false)
  eq(jobs.transition(job, "waiting_user", { session = session, waiting_kind = "question" }), true)
  eq(job.waiting_kind, "question")
  eq(jobs.transition(job, "running", { session = session }), true)
  eq(job.waiting_kind, nil)
  eq(jobs.transition(job, "pending_apply", { session = session }), true)
  eq(jobs.transition(job, "conflict", { session = session, conflict_kind = "agent" }), false)
  eq(
    jobs.transition(job, "conflict", {
      session = session,
      conflict_kind = "agent",
      conflict_payload = { base = "private" },
    }),
    true
  )
  eq(jobs.transition(job, "completed", { session = session }), true)
  eq(job.conflict_payload, nil)
  eq(jobs.transition(job, "completed", { session = session }), true)
  eq(jobs.transition(job, "running", { session = session }), false)
end

T["Job transition matrix covers every state pair"] = function()
  local jobs = require("opencode.job")
  local states =
    { "running", "waiting_user", "pending_apply", "conflict", "completed", "cancelled", "error", "scope_violation" }
  local allowed = {
    running = {
      waiting_user = true,
      pending_apply = true,
      completed = true,
      cancelled = true,
      error = true,
      scope_violation = true,
    },
    waiting_user = { running = true, cancelled = true, error = true },
    pending_apply = { completed = true, conflict = true, cancelled = true, error = true, scope_violation = true },
    conflict = { completed = true, cancelled = true, error = true },
  }
  for _, from in ipairs(states) do
    for _, to in ipairs(states) do
      local session = { active_job_key = "job" }
      local job =
        { key = "job", root = "/root", state = from, waiting_kind = from == "waiting_user" and "question" or nil }
      if from == "conflict" then
        job.conflict_kind, job.conflict_payload = "agent", { private = true }
      end
      local attrs = { session = session }
      if to == "waiting_user" then
        attrs.waiting_kind = "question"
      elseif to == "conflict" then
        attrs.conflict_kind, attrs.conflict_payload = "agent", { private = true }
      end
      local expected = (from == to and jobs.terminal(from) or allowed[from] and allowed[from][to]) == true
      eq(jobs.transition(job, to, attrs), expected, from .. " -> " .. to)
      eq(job.state, expected and to or from, from .. " -> " .. to)
    end
  end
end

T["stale remote reply cannot resume a waiting Job"] = function()
  package.loaded["opencode.interaction"] = nil
  local runtime = require("opencode.runtime").new("/root")
  local session = { id = "ses_1", active_job_key = "job" }
  local job =
    { key = "job", root = "/root", session_id = session.id, state = "waiting_user", waiting_kind = "question" }
  runtime.sessions[session.id], runtime.jobs[job.key] = session, job
  require("opencode.events").route(runtime, {
    type = "question.replied",
    properties = { sessionID = session.id, requestID = "stale" },
  })
  eq(job.state, "waiting_user")
  eq(job.waiting_kind, "question")
end

T["permission policy fails closed and limits persistent approval"] = function()
  local policy = require("opencode.events").permission_policy
  for _, name in ipairs({ "edit", "write", "apply_patch", "bash", "task", "external_directory", "custom" }) do
    eq(policy(name), "hard_reject", name)
  end
  eq(policy("read"), "ask_once")
  eq(policy("webfetch"), "ask_once_always")
end

T["interaction queue deduplicates remote identity in FIFO order"] = function()
  package.loaded["opencode.interaction"] = nil
  local interactions = require("opencode.interaction")
  local first = interactions.enqueue({
    kind = "question",
    root = "/root",
    session_id = "ses_1",
    job_key = "job_1",
    request_id = "req_1",
    payload = {},
  })
  local duplicate, added = interactions.enqueue({
    kind = "question",
    root = "/root",
    session_id = "ses_1",
    job_key = "job_1",
    request_id = "req_1",
    payload = {},
  })
  local second = interactions.enqueue({
    kind = "permission",
    root = "/root",
    session_id = "ses_2",
    job_key = "job_2",
    request_id = "req_2",
    payload = {},
  })
  eq(duplicate.id, first.id)
  eq(added, false)
  eq({ interactions.queue[1].id, interactions.queue[2].id }, { first.id, second.id })
  interactions.remove_by_job("/root", "job_1")
  eq(#interactions.queue, 1)
end

T["cancel one is local and isolated even when abort fails"] = function()
  package.loaded["opencode.interaction"] = nil
  local Promise = require("opencode.promise")
  local runtime = require("opencode.runtime").new("/root")
  runtime.client = {
    abort = function(_, id)
      eq(id, "ses_a")
      return Promise.reject({ error_class = "http" })
    end,
  }
  local a = { key = "job_a", root = "/root", session_id = "ses_a", state = "running", mode = "plan" }
  local b = { key = "job_b", root = "/root", session_id = "ses_b", state = "running", mode = "plan" }
  runtime.sessions.ses_a = { id = "ses_a", active_job_key = a.key }
  runtime.sessions.ses_b = { id = "ses_b", active_job_key = b.key }
  runtime.jobs[a.key], runtime.jobs[b.key] = a, b
  local report
  require("opencode.job").cancel(runtime, a.key):next(function(value)
    report = value
  end)
  eq(vim.wait(100, function()
    return report ~= nil
  end), true)
  eq({ a.state, b.state, report.cancelled, report.errors }, { "cancelled", "running", 1, 1 })
  eq(runtime.sessions.ses_a.active_job_key, nil)
  eq(runtime.sessions.ses_b.active_job_key, b.key)
end

return T
