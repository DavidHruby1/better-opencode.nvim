local M = { seen = {}, last_focus_safe = true }

local terminal_states = { completed = true, error = true, scope_violation = true }
local levels = {
  completed = vim.log.levels.INFO,
  conflict = vim.log.levels.WARN,
  question = vim.log.levels.INFO,
  permission = vim.log.levels.INFO,
  error = vim.log.levels.ERROR,
  scope_violation = vim.log.levels.ERROR,
}
local safe_classes = {
  agent_conflict = true,
  agent_unavailable = true,
  ambiguous_lsp_root = true,
  apply_error = true,
  assistant_message_count = true,
  command_unsupported = true,
  config_parse = true,
  custom_tool = true,
  decode = true,
  disconnected = true,
  disk_read = true,
  external_change = true,
  file_edited = true,
  hard_denied_permission = true,
  http = true,
  interaction_failed = true,
  interaction_locked = true,
  invalid_result = true,
  invalid_structured_output = true,
  manual_cleanup = true,
  merge_temp = true,
  merge_process = true,
  missing_result = true,
  missing_pending_request = true,
  missing_session = true,
  mode_unavailable = true,
  no_active_job = true,
  permission = true,
  process_identity = true,
  reconciling = true,
  reconciliation_blocked = true,
  reconciliation_failed = true,
  root_mismatch = true,
  runtime_busy = true,
  runtime_disconnected = true,
  runtime_not_ready = true,
  runtime_not_running = true,
  runtime_stopped = true,
  runtime_stopping = true,
  save_or_reconcile = true,
  server_exit = true,
  server_spawn = true,
  scope_overlap = true,
  scope_violation = true,
  session_active = true,
  session_busy = true,
  session_inventory = true,
  session_verification = true,
  sse_disconnected = true,
  sse_spawn = true,
  stale_generation = true,
  stale_source = true,
  starting = true,
  startup_timeout = true,
  timeout = true,
  transport_closed = true,
  unknown_session = true,
  unknown_session_status = true,
  unsupported_version = true,
  write_failed = true,
}

local actionable_messages = {
  agent_unavailable = "agent_unavailable: OpenCode must provide the primary build agent",
  ambiguous_lsp_root = "ambiguous_lsp_root: multiple active LSP workspaces contain this file; align their roots or disable the extra client (see docs/RECOVERY.md)",
  config_parse = "config_parse: OpenCode config is invalid; fix it or use a clean config (see docs/RECOVERY.md)",
  custom_tool = "custom_tool: custom OpenCode tools are blocked; use a clean config (see docs/RECOVERY.md)",
  decode = "decode: OpenCode returned an invalid response; restart the owned runtime (see docs/RECOVERY.md)",
  disk_read = "disk_read: the source file could not be read; check its permissions and try again",
  disconnected = "disconnected: the owned OpenCode runtime is disconnected; restart it and retry",
  reconciliation_failed = "reconciliation_failed: OpenCode state could not be verified; retry reconciliation or restart the runtime",
  http = "http: OpenCode request failed; retry or run :checkhealth opencode (see docs/RECOVERY.md)",
  server_exit = "server_exit: owned OpenCode server exited during startup; run :checkhealth opencode (see docs/RECOVERY.md)",
  server_spawn = "server_spawn: owned OpenCode startup failed; check runtime.binary and run :checkhealth opencode (see docs/RECOVERY.md)",
  startup_timeout = "startup_timeout: owned OpenCode startup timed out; run :checkhealth opencode (see docs/RECOVERY.md)",
  timeout = "timeout: OpenCode request timed out; retry or run :checkhealth opencode (see docs/RECOVERY.md)",
  unsupported_version = "unsupported_version: unsupported OpenCode version; install exactly 1.17.3 or 1.18.9 (see docs/RECOVERY.md)",
}

---Captures the editor window and cursor so a notification can prove it did not move normal UI focus.
local function focus_snapshot()
  local current = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(current)
  return { window = current, cursor = cursor }
end

---Compares the editor focus facts captured before and after a notification.
local function same_focus(before, after)
  return before.window == after.window and vim.deep_equal(before.cursor, after.cursor)
end

local function safe_class(value)
  if type(value) == "table" then
    value = value.error_class
  end
  value = tostring(value or "error")
  return safe_classes[value] and value or "error"
end

local function safe_endpoint(value)
  if type(value) ~= "string" then
    return nil
  end
  local endpoint = require("opencode.log").endpoint(value)
  return #endpoint <= 120 and endpoint or nil
end

---Builds an allowlisted startup or config diagnostic from structured error metadata.
---Only bounded, sanitized endpoint and HTTP status fields may supplement fixed messages; all other input is ignored.
local function safe_message(error)
  local class = safe_class(error)
  local message = actionable_messages[class] or class
  if type(error) ~= "table" or (class ~= "http" and class ~= "timeout" and class ~= "decode") then
    return "OpenCode: " .. message
  end
  local details = {}
  local endpoint = safe_endpoint(error.endpoint)
  if endpoint then
    table.insert(details, "endpoint=" .. endpoint)
  end
  if
    class == "http"
    and type(error.status) == "number"
    and error.status % 1 == 0
    and error.status >= 100
    and error.status <= 599
  then
    table.insert(details, "status=" .. error.status)
  end
  return "OpenCode: " .. message .. (#details > 0 and " (" .. table.concat(details, ", ") .. ")" or "")
end

local function generic(kind, error)
  local before = focus_snapshot()
  vim.notify(safe_message(error), vim.log.levels[kind], { title = "OpenCode" })
  M.last_focus_safe = same_focus(before, focus_snapshot())
end

---Copies only notification identity from an event-owning Job before any UI callback can change selection.
---The returned metadata contains a root basename, collision-safe Session ID, mode, state, and safe error class;
---it deliberately excludes prompts, titles, paths, summaries, replacements, and diff data.
---@param runtime table
---@param job table
---@return table
function M.snapshot(runtime, job)
  local session = runtime and runtime.sessions and runtime.sessions[job.session_id] or nil
  local session_short_id = session and session.short_id
  if runtime and session then
    for _, item in ipairs(require("opencode.ui.status").snapshot(runtime).sessions) do
      if item.id == job.session_id then
        session_short_id = item.short_id
        break
      end
    end
  end
  return vim.deepcopy({
    root = vim.fs.basename((runtime and runtime.root) or job.root or ""),
    root_key = runtime and runtime.root_hash or vim.fn.sha256(job.root or ""),
    session_short_id = session_short_id or tostring(job.session_id or "unknown"):sub(-8),
    mode = "build",
    state = job.state or "unknown",
    job_key = job.key or "unknown",
    error_class = safe_class(job.error_class),
  })
end

---Formats one explicit background event with the same text identity in every terminal notification.
---No event accepts user content, so notifications stay safe even when an OpenCode error contains a response body.
---@param kind string
---@param metadata table
---@return string
function M.format(kind, metadata)
  local identity = string.format(
    "[%s] Session %s %s state=%s",
    metadata.root,
    metadata.session_short_id,
    metadata.mode,
    metadata.state
  )
  if kind == "completed" then
    return identity .. ": completed"
  end
  if kind == "conflict" then
    return identity .. ": conflict needs review"
  end
  if kind == "question" then
    return identity .. ": question waiting"
  end
  if kind == "permission" then
    return identity .. ": permission waiting"
  end
  if kind == "scope_violation" then
    return identity .. ": scope violation, proposal rejected"
  end
  return identity .. ": error " .. safe_class(metadata.error_class)
end

---Emits one metadata-only notification without changing editor focus or cursor.
---Terminal states deduplicate by root and Job key; queued questions, permissions, and conflicts deduplicate by Job.
---@param kind string
---@param metadata table
---@param runtime? table
---@return boolean
function M.emit(kind, metadata, runtime)
  local opts = require("opencode.config").opts.notify
  if opts.enabled == false then
    return false
  end
  local dedupe_key = metadata.root_key .. ":" .. metadata.job_key .. ":" .. kind
  if
    (terminal_states[metadata.state] or kind == "conflict" or kind == "question" or kind == "permission")
    and M.seen[dedupe_key]
  then
    return false
  end
  M.seen[dedupe_key] = true
  local before = focus_snapshot()
  local notify_opts = vim.deepcopy(opts.opts or {})
  notify_opts.title = notify_opts.title or "OpenCode"
  vim.notify(M.format(kind, metadata), levels[kind] or vim.log.levels.INFO, notify_opts)
  M.last_focus_safe = same_focus(before, focus_snapshot())
  return true
end

---Reports a safe error for command failures that do not belong to a Job.
---Known startup failures use fixed guidance and bounded structured metadata; arbitrary error text is never shown.
---@param error string|table
function M.error(error)
  generic("ERROR", error)
end

---Reports a safe warning class without changing editor focus or exposing external error text.
---@param error_class string
function M.warn(error_class)
  generic("WARN", error_class)
end

---Shows a colorless metadata status snapshot for diagnostics without exposing Session content.
---@param runtime table
function M.diagnostics(runtime)
  local before = focus_snapshot()
  local status = require("opencode.ui.status")
  vim.notify(status.text(status.snapshot(runtime)), vim.log.levels.INFO, { title = "OpenCode diagnostics" })
  M.last_focus_safe = same_focus(before, focus_snapshot())
end

---Returns whether the last emit callback preserved the captured editor focus facts.
---@return boolean
function M.focus_safe()
  return M.last_focus_safe
end

return M
