local M = { queue = {}, current = nil, sequence = 0, remote = {} }

local remote_kinds = { question = true, permission = true }

local function remote_key(request)
  if not request.request_id then
    return nil
  end
  return (request.root or "") .. ":" .. request.session_id .. ":" .. request.job_key .. ":" .. request.request_id
end

local function resolve(request)
  local runtime = require("opencode.runtime").for_root(request.root)
  if not runtime then
    return nil
  end
  local job = runtime.jobs[request.job_key]
  if not job or job.session_id ~= request.session_id then
    return nil
  end
  return runtime, job
end

---Reopens prompt dispatch after a remote dialog.
---The request identity is resolved again because its Runtime may have shut down while the question or permission was open.
local function unlock(request)
  if not remote_kinds[request.kind] then
    return
  end
  local runtime = resolve(request)
  if runtime then
    runtime.interaction_locked = false
    runtime.prompt_locked = request.prompt_was_locked or runtime.reconciling or runtime.reconciliation_required == true
  end
end

---Displays the oldest queued request after resolving its Runtime and Job from immutable identity.
---Only this function changes queued to shown. Remote questions and permissions lock prompt dispatch until their request is confirmed,
---so the FIFO remains serialized without depending on a terminal pane.
function M.advance()
  if M.current then
    return
  end
  while #M.queue > 0 do
    local request = table.remove(M.queue, 1)
    local runtime = resolve(request)
    if runtime then
      M.current = request
      request.state = "shown"
      if remote_kinds[request.kind] then
        request.prompt_was_locked = runtime.prompt_locked == true
        runtime.interaction_locked, runtime.prompt_locked = true, true
      end
      require("opencode.ui.dialog").show(request)
      return
    end
    request.state = "closed"
  end
end

---Adds an immutable request to the global FIFO and deduplicates remote requests by Session, Job, and ID.
---The monotonic local ID records main-loop arrival order without exposing private request content.
---@param request table
---@return table
---@return boolean
function M.enqueue(request)
  local key = remote_key(request)
  if key and M.remote[key] then
    return M.remote[key], false
  end
  M.sequence = M.sequence + 1
  local copy = vim.deepcopy(request)
  copy.id, copy.state = string.format("dialog_%08d", M.sequence), "queued"
  table.insert(M.queue, copy)
  if key then
    M.remote[key] = copy
  end
  vim.schedule(M.advance)
  return copy, true
end

---Completes only the currently displayed request and advances the FIFO.
---Stale callbacks are ignored by ID so they cannot close a newer dialog.
---@param id string
function M.complete_current(id)
  if not M.current or M.current.id ~= id then
    return false
  end
  local request = M.current
  request.state = "closed"
  local key = remote_key(request)
  if key then
    M.remote[key] = nil
  end
  M.current = nil
  unlock(request)
  vim.schedule(M.advance)
  return true
end

---Removes every queued or shown request owned by one Job.
---A removed current request releases its interaction lock before the next request is shown.
function M.remove_by_job(root, job_key)
  local kept = {}
  for _, request in ipairs(M.queue) do
    if request.root == root and request.job_key == job_key then
      request.state = "closed"
      local key = remote_key(request)
      if key then
        M.remote[key] = nil
      end
    else
      table.insert(kept, request)
    end
  end
  M.queue = kept
  if M.current and M.current.root == root and M.current.job_key == job_key then
    M.complete_current(M.current.id)
  end
end

---Rejects the displayed remote request owned by a cancelling Job, then removes all its dialogs.
---The HTTP command is best-effort and queue progress never waits for its response.
---@param runtime table
---@param job table
function M.reject_by_job(runtime, job)
  local request = M.current
  if request and request.root == job.root and request.job_key == job.key and remote_kinds[request.kind] then
    if request.kind == "question" then
      runtime.client:question_reject(request.request_id):catch(function() end)
    else
      runtime.client:permission_reply(request.request_id, "reject"):catch(function() end)
    end
  end
  M.remove_by_job(job.root, job.key)
end

function M.mark_awaiting(id)
  if M.current and M.current.id == id then
    M.current.state = "awaiting_confirmation"
    return true
  end
  return false
end

---Replaces the displayed conflict after a retry changes its conflict kind.
---The same queue slot is retained so no later dialog can overtake the new agent-conflict choices.
function M.replace_current_conflict(root, job_key, kind, payload)
  if not M.current or M.current.root ~= root or M.current.job_key ~= job_key then
    return false
  end
  M.current.kind = kind
  M.current.payload = vim.deepcopy(payload)
  return true
end

---Checks remote identity without changing queue, lock, or Job state.
---Reply events use this before transitioning so stale IDs cannot make a waiting Job run.
function M.has_remote(session_id, job_key, request_id, root)
  if not request_id then
    return false
  end
  return M.remote[(root or "") .. ":" .. session_id .. ":" .. job_key .. ":" .. request_id] ~= nil
end

---Completes a remote request only when its Session, Job, and request ID all match.
---This is the SSE confirmation path; an HTTP response cannot invoke it.
function M.confirm(session_id, job_key, request_id, root)
  local key = (root or "") .. ":" .. session_id .. ":" .. job_key .. ":" .. request_id
  local request = M.remote[key]
  if not request then
    return false
  end
  if M.current and M.current.id == request.id then
    return M.complete_current(request.id)
  end
  for index, queued in ipairs(M.queue) do
    if queued.id == request.id then
      table.remove(M.queue, index)
      queued.state, M.remote[key] = "closed", nil
      return true
    end
  end
  return false
end

return M
