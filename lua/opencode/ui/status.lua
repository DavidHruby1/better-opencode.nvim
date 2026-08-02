local M = {}

local function short_id(id, length)
  id = tostring(id or "unknown")
  return id:sub(-length)
end

local function collision_safe_ids(sessions)
  local length = 8
  while true do
    local seen, collision = {}, false
    for _, session in ipairs(sessions) do
      local value = short_id(session.id, length)
      collision = collision or seen[value] == true
      seen[value] = true
    end
    if not collision then
      break
    end
    length = length + 2
  end
  for _, session in ipairs(sessions) do
    session.short_id = short_id(session.id, length)
  end
end

local function truncate(value, width)
  value = tostring(value or "")
  if width <= 0 or vim.fn.strdisplaywidth(value) <= width then
    return value
  end
  if width <= 3 then
    return vim.fn.strcharpart(value, 0, width)
  end
  local result = ""
  for count = vim.fn.strchars(value), 0, -1 do
    local candidate = vim.fn.strcharpart(value, 0, count)
    if vim.fn.strdisplaywidth(candidate) <= width - 3 then
      result = candidate
      break
    end
  end
  return result .. "..."
end

local function session_availability(runtime, session, job)
  if job and not require("opencode.job").terminal(job.state) then
    return "active"
  end
  return session.availability or "reusable"
end

local function job_kind(job)
  if not job then
    return "none"
  end
  return job.conflict_kind or job.waiting_kind or job.mode or "unknown"
end

---Builds one immutable, privacy-safe view of Runtime status for foreground and background UI.
---The registry and Job tables are read once, copied into plain metadata, and never changed; Job rows include
---their cancellation key, mode, file name, state, and short ID without HTTP or transcript selection.
---@param runtime table
---@return table
function M.snapshot(runtime)
  local sessions, source = {}, {}
  for id, session in pairs(runtime.sessions or {}) do
    source[id] = session
    table.insert(sessions, { id = id })
  end
  collision_safe_ids(sessions)
  table.sort(sessions, function(a, b)
    return a.id < b.id
  end)

  local snapshot = {
    root = vim.fs.basename(runtime.root or ""),
    runtime_state = runtime.state or "unknown",
    prompt_blocker = runtime.prompt_blocker and runtime:prompt_blocker() or nil,
    tui_status = runtime.tui_status or "unknown",
    compatibility = runtime.profile and runtime.profile.version or "unknown",
    foreground = require("opencode.runtime").current() == runtime,
    sessions = {},
    jobs = {},
    counts = { active_sessions = 0, reusable_sessions = 0, active_jobs = 0, terminal_jobs = 0 },
  }
  for _, item in ipairs(sessions) do
    local session = source[item.id]
    local job = session.active_job_key and runtime.jobs and runtime.jobs[session.active_job_key]
    local availability = session_availability(runtime, session, job)
    item.title = session.title or "Untitled"
    item.last_mode = session.last_mode or (job and job.mode) or "unknown"
    item.availability = availability
    item.job_state = job and job.state or session.last_job_state or "idle"
    item.job_kind = job_kind(job)
    item.foreground = runtime.selected_session_id == session.id
    table.insert(snapshot.sessions, item)
    if availability == "active" then
      snapshot.counts.active_sessions = snapshot.counts.active_sessions + 1
    else
      snapshot.counts.reusable_sessions = snapshot.counts.reusable_sessions + 1
    end
  end
  for key, job in pairs(runtime.jobs or {}) do
    local session = source[job.session_id]
    local session_short_id = session and session.short_id
    for _, item in ipairs(snapshot.sessions) do
      if item.id == job.session_id then
        session_short_id = item.short_id
        break
      end
    end
    local row = {
      key = key,
      session = session_short_id or short_id(job.session_id, 8),
      job = short_id(job.user_message_id or key, 8),
      mode = job.mode or "unknown",
      file = job.path and vim.fs.basename(job.path) or "unknown",
      state = job.state or "unknown",
      kind = job_kind(job),
    }
    table.insert(snapshot.jobs, row)
    if require("opencode.job").terminal(job.state) then
      snapshot.counts.terminal_jobs = snapshot.counts.terminal_jobs + 1
    else
      snapshot.counts.active_jobs = snapshot.counts.active_jobs + 1
    end
  end
  table.sort(snapshot.jobs, function(a, b)
    return a.key < b.key
  end)
  return snapshot
end

---Returns every active Job with its exact cancellation key and display metadata without changing transcript selection.
---The rows come from one Runtime snapshot, and terminal Jobs are excluded before callers receive them.
---@param runtime table
---@return table[]
function M.jobs(runtime)
  local rows = {}
  for _, job in ipairs(M.snapshot(runtime).jobs) do
    if not require("opencode.job").terminal(job.state) then
      table.insert(rows, {
        root = vim.fs.basename(runtime.root),
        key = job.key,
        session = job.session,
        job = job.job,
        mode = job.mode,
        file = job.file,
        state = job.state,
        kind = job.kind,
      })
    end
  end
  return rows
end

---Renders a colorless status summary with separate Runtime, prompt blocker, and TUI truth.
---Only titles and roots are width-limited; short IDs, states, modes, and lifecycle diagnostics remain complete.
---@param snapshot table
---@param width? integer
---@return string
function M.text(snapshot, width)
  width = width or 120
  local counts = snapshot.counts
  local result = string.format(
    "%s | Runtime %s | TUI %s | Blocker %s | OpenCode %s | Sessions active=%d reusable=%d | Jobs active=%d terminal=%d",
    truncate(snapshot.root, math.max(12, math.floor(width * 0.18))),
    snapshot.runtime_state,
    snapshot.tui_status,
    snapshot.prompt_blocker or "none",
    snapshot.compatibility,
    counts.active_sessions,
    counts.reusable_sessions,
    counts.active_jobs,
    counts.terminal_jobs
  )
  for _, session in ipairs(snapshot.sessions) do
    local marker = session.foreground and "foreground" or "background"
    local title = truncate(session.title, math.max(12, math.floor(width * 0.24)))
    result = result
      .. string.format(
        "\n%s Session %s (%s) mode=%s availability=%s Job=%s/%s",
        marker,
        session.short_id,
        title,
        session.last_mode,
        session.availability,
        session.job_state,
        session.job_kind
      )
  end
  return result
end

return M
