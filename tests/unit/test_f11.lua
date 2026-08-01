local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["metadata logger rejects content-shaped fields and normalizes endpoints"] = function()
  local log = require("opencode.log")
  local safe =
    assert(log.sanitize({ root_hash = "/home/user/project", endpoint = "https://127.0.0.1:1234/session?secret=1" }))
  eq(safe.root_hash:match("^[0-9a-f]+$"), safe.root_hash)
  eq(safe.root_hash:find("/", 1, true), nil)
  eq(safe.endpoint, "/session")
  eq(select(2, log.sanitize({ prompt = "secret" })), "unknown_log_field")
  eq(log.error_class({ error_class = "curl body secret" }), "error")
end

T["status snapshot is colorless and collision safe"] = function()
  local Runtime = require("opencode.runtime")
  local status = require("opencode.ui.status")
  local runtime = Runtime.new("/tmp/status-root")
  runtime.state, runtime.profile = "ready", { version = "1.17.3" }
  runtime.sessions = {
    first = {
      id = "ses_firstsame-tail",
      title = "A very long Session title that should be shortened",
      short_id = nil,
      last_mode = "build",
    },
    second = { id = "ses_secondsame-tail", title = "Second", short_id = nil, last_mode = "plan" },
  }
  runtime.jobs = {
    job = { key = "job", session_id = "first", user_message_id = "msg_first", mode = "build", state = "running" },
  }
  runtime.sessions.first.active_job_key = "job"
  Runtime.registry[runtime.root] = runtime
  Runtime.active_root = runtime.root
  local snapshot = status.snapshot(runtime)
  eq(snapshot.compatibility, "1.17.3")
  eq(snapshot.counts.active_sessions, 1)
  eq(snapshot.counts.reusable_sessions, 1)
  eq(snapshot.sessions[1].short_id ~= snapshot.sessions[2].short_id, true)
  eq(status.text(snapshot, 60):find("Runtime ready", 1, true) ~= nil, true)
  Runtime.registry[runtime.root] = nil
  Runtime.active_root = nil
end

T["notification templates deduplicate without content or focus changes"] = function()
  local notify = require("opencode.ui.notify")
  local original = vim.notify
  local calls = {}
  vim.notify = function(message, level, opts)
    table.insert(calls, { message = message, level = level, opts = opts })
  end
  notify.seen = {}
  local runtime = require("opencode.runtime").new("/tmp/notify-root")
  runtime.root_hash = vim.fn.sha256(runtime.root)
  local job = {
    key = "job",
    session_id = "session",
    mode = "build",
    state = "completed",
    root = runtime.root,
  }
  runtime.sessions.session = { id = "session", short_id = "session1" }
  local metadata = notify.snapshot(runtime, job)
  eq(notify.emit("completed", metadata, runtime), true)
  eq(notify.emit("completed", metadata, runtime), false)
  eq(#calls, 1)
  eq(calls[1].message:find("/tmp", 1, true), nil)
  eq(calls[1].message:find("secret", 1, true), nil)
  eq(notify.focus_safe(), true)
  vim.notify = original
end

T["structured startup notifications keep only safe actionable transport details"] = function()
  local notify = require("opencode.ui.notify")
  local original = vim.notify
  local messages = {}
  vim.notify = function(message)
    table.insert(messages, message)
  end

  local ok, failure = xpcall(function()
    local cases = {
      { error_class = "custom_tool", expected = "custom OpenCode tools are blocked" },
      { error_class = "config_parse", expected = "OpenCode config could not be parsed" },
      {
        error_class = "http",
        endpoint = "https://user:credential@example.test/session/private-id?token=secret",
        status = 503,
        body = "HTTP_RESPONSE_SECRET",
        message = "raw exception /private/project",
        expected = "OpenCode request failed",
        details = { "endpoint=/session", "status=503" },
      },
      {
        error_class = "timeout",
        endpoint = "http://user:credential@example.test/health/private-id?token=secret",
        timeout = 2500,
        body = "TIMEOUT_RESPONSE_SECRET",
        message = "raw timeout exception /private/project",
        expected = "OpenCode request timed out",
        details = { "endpoint=/health" },
      },
      {
        error_class = "decode",
        endpoint = "http://user:credential@example.test/doc?token=secret",
        status = 700,
        body = "DECODE_RESPONSE_SECRET",
        message = "raw decode exception /private/project",
        expected = "OpenCode returned an invalid response",
        details = { "endpoint=/doc" },
      },
      { error_class = "server_spawn", expected = "owned OpenCode startup failed" },
      { error_class = "startup_timeout", expected = "owned OpenCode startup timed out" },
      { error_class = "unsupported_version", expected = "unsupported OpenCode version" },
    }

    for _, case in ipairs(cases) do
      notify.error(case)
      local message = messages[#messages]
      eq(message:find(case.expected, 1, true) ~= nil, true, case.error_class)
      for _, detail in ipairs(case.details or {}) do
        eq(message:find(detail, 1, true) ~= nil, true, case.error_class)
      end
      for _, secret in ipairs({
        "HTTP_RESPONSE_SECRET",
        "TIMEOUT_RESPONSE_SECRET",
        "DECODE_RESPONSE_SECRET",
        "credential",
        "secret",
        "raw exception",
        "/private/project",
      }) do
        eq(message:find(secret, 1, true), nil, case.error_class .. " leaked " .. secret)
      end
      eq(message:find("status=700", 1, true), nil, case.error_class)
    end

    notify.error("raw exception /private/project with credential")
    eq(messages[#messages], "OpenCode: error")
  end, debug.traceback)

  vim.notify = original
  assert(ok, failure)
end

T["configuration validation exposes only documented source scopes"] = function()
  local config = require("opencode.config")
  eq(select(1, config.validate({ runtime = { binary = "opencode", startup_timeout = 1 } })), true)
  eq(select(2, config.validate({ runtime = { unknown = true } })).scope, "runtime.unknown")
  eq(select(2, config.validate({ sidebar = { width = 2 } })).reason, "type_or_range")
  eq(select(2, config.validate({ notify = { opts = "content" } })).scope, "notify.opts")
end

T["configuration documentation names every supported option"] = function()
  local documented = table.concat(vim.fn.readfile("docs/CONFIGURATION.md"), "\n")
  for _, key in ipairs({
    "runtime.binary",
    "runtime.startup_timeout",
    "runtime.shutdown_timeout",
    "runtime.reconnect.max_attempts",
    "runtime.reconnect.backoff_ms",
    "runtime.reconnect.max_backoff_ms",
    "sidebar.width",
    "contexts",
    "ask.snacks.win",
    "notify.enabled",
    "notify.opts",
  }) do
    eq(documented:find("`" .. key .. "`", 1, true) ~= nil, true, key)
  end
end

T["acceptance manifest matches all documented IDs"] = function()
  local report = dofile("tests/release/validator.lua").validate(".")
  eq(report.ok, true, table.concat(report.errors, "; "))
  eq(report.manifest_count, 65)
end

T["evidence generator stays failed without result artifacts"] = function()
  local output = vim.fn.tempname()
  local evidence = dofile("tests/release/evidence.lua")
  eq(evidence.generate(".", "tests/release/results/index.lua", output), false)
  local text = table.concat(vim.fn.readfile(output), "\n")
  eq(text:find("Overall: %*%*FAIL%*%*", 1, false) ~= nil, true)
  vim.uv.fs_unlink(output)
end

return T
