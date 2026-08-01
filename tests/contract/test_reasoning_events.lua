local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local versions = { "1.17.3", "1.18.9" }

---Loads a frozen event fixture without changing it, keeping event compatibility separate from /doc fixtures.
local function fixture(version, kind)
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
  local path = root .. "/tests/fixtures/reasoning-" .. version .. "-" .. kind .. ".json"
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

---Builds a Runtime with one exact assistant mapping and records calls at the status module boundary.
---The real Runtime and event router remain active while the UI module is restored after the case.
local function with_routing(callback)
  local module_name = "opencode.ui.request_status"
  local previous_module = package.loaded[module_name]
  local runtime = require("opencode.runtime").new("/reasoning-events")
  local calls = {}
  local status = {}
  package.loaded[module_name] = {
    replace_reasoning = function(received, ...)
      table.insert(calls, { kind = "replace", status = received, args = { ... } })
    end,
    append_reasoning = function(received, ...)
      table.insert(calls, { kind = "append", status = received, args = { ... } })
    end,
  }
  local job
  local ok, failure = xpcall(function()
    job = {
      key = "ses_fixture:user_fixture",
      root = runtime.root,
      session_id = "ses_fixture",
      user_message_id = "user_fixture",
      mode = "build",
      state = "running",
      request_status = status,
      assistant_message_ids = {},
      assistant_messages = {},
    }
    runtime.jobs[job.key] = job
    runtime.sessions[job.session_id] = { id = job.session_id, active_job_key = job.key }
    runtime:route_event({
      type = "message.updated",
      properties = {
        info = {
          id = "assistant_fixture",
          role = "assistant",
          sessionID = job.session_id,
          parentID = job.user_message_id,
        },
      },
    })
    callback(runtime, job, calls, status)
  end, debug.traceback)
  package.loaded[module_name] = previous_module
  assert(ok, failure)
end

T["AC-EVT-06 frozen v1.17.3 and v1.18.9 reasoning fixtures keep exact update and delta shapes"] = function()
  for _, version in ipairs(versions) do
    local updated = fixture(version, "updated")
    local delta = fixture(version, "delta")
    eq(updated, {
      type = "message.part.updated",
      properties = {
        sessionID = "ses_fixture",
        part = {
          id = "part_reasoning",
          sessionID = "ses_fixture",
          messageID = "assistant_fixture",
          type = "reasoning",
          text = "reasoning " .. version,
          time = { start = 1710000000000 },
        },
      },
    }, version)
    eq(delta, {
      type = "message.part.delta",
      properties = {
        sessionID = "ses_fixture",
        messageID = "assistant_fixture",
        partID = "part_reasoning",
        field = "text",
        delta = " delta " .. version,
      },
    }, version)
    eq(delta.properties.type, nil, version)
  end
end

T["reasoning events route by exact Session, assistant, and part identity"] = function()
  for _, version in ipairs(versions) do
    local updated, delta = fixture(version, "updated"), fixture(version, "delta")
    with_routing(function(runtime, job, calls, status)
      runtime:route_event(updated)
      runtime:route_event(delta)
      eq(calls, {
        {
          kind = "replace",
          status = status,
          args = { "ses_fixture", "assistant_fixture", "part_reasoning", "reasoning " .. version },
        },
        {
          kind = "append",
          status = status,
          args = { "ses_fixture", "assistant_fixture", "part_reasoning", " delta " .. version },
        },
      }, version)
      eq(job.late_event_count, nil, version)
    end)
  end
end

T["wrong type, field, Session, Message, part, and terminal Job events fail closed"] = function()
  local updated, delta = fixture("1.18.9", "updated"), fixture("1.18.9", "delta")
  with_routing(function(runtime, job, calls)
    local wrong_type = vim.deepcopy(updated)
    wrong_type.properties.part.type = "text"
    runtime:route_event(wrong_type)
    local wrong_field = vim.deepcopy(delta)
    wrong_field.properties.field = "value"
    runtime:route_event(wrong_field)
    eq(#calls, 0)

    local wrong_session = vim.deepcopy(updated)
    wrong_session.properties.sessionID = "ses_other"
    wrong_session.properties.part.sessionID = "ses_other"
    runtime:route_event(wrong_session)
    local wrong_message = vim.deepcopy(delta)
    wrong_message.properties.messageID = "assistant_other"
    runtime:route_event(wrong_message)
    eq(#calls, 0)

    local old = vim.deepcopy(job)
    old.key, old.user_message_id, old.state = "ses_fixture:user_old", "user_old", "completed"
    runtime.jobs[old.key] = old
    runtime:route_event({
      type = "message.updated",
      properties = {
        info = {
          id = "assistant_old",
          role = "assistant",
          sessionID = "ses_fixture",
          parentID = old.user_message_id,
        },
      },
    })
    local old_event = vim.deepcopy(updated)
    old_event.properties.part.messageID = "assistant_old"
    runtime:route_event(old_event)
    eq(#calls, 0)
    eq(old.late_event_count, 2)
    eq(job.late_event_count, nil)
  end)
end

T["delta-first and unknown part identities never borrow the active status"] = function()
  local delta = fixture("1.17.3", "delta")
  with_routing(function(runtime, _, calls)
    runtime:route_event(delta)
    eq({ calls[1].kind, calls[1].args[3] }, { "append", "part_reasoning" })
    local unknown = vim.deepcopy(delta)
    unknown.properties.partID = "part_unknown"
    runtime:route_event(unknown)
    eq({ #calls, calls[2].kind, calls[2].args[3] }, { 2, "append", "part_unknown" })
  end)
end

return T
