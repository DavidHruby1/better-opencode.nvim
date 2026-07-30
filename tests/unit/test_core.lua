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

return T
