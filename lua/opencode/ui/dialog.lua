local M = {}

local function identity(request)
  return vim.fs.basename(request.root) .. " " .. (request.session_short_id or request.session_id:sub(-8))
end

local function context(request)
  local runtime = require("opencode.runtime").for_root(request.root)
  local job = runtime and runtime.jobs[request.job_key]
  return runtime, job
end

local function close(request, state)
  local runtime, job = context(request)
  if job and state then
    require("opencode.job").transition(job, state, { session = runtime.sessions[job.session_id] })
  end
  require("opencode.interaction").complete_current(request.id)
end

local function retry_visible(request, error_class)
  if request.state == "closed" then
    return
  end
  require("opencode.ui.notify").error(error_class or "interaction_failed")
  vim.schedule(function()
    if request.state ~= "closed" then
      M.show(request)
    end
  end)
end

local function submit(request, promise)
  promise
    :next(function()
      require("opencode.interaction").mark_awaiting(request.id)
    end)
    :catch(function(err)
      retry_visible(request, type(err) == "table" and err.error_class or "http")
    end)
end

local function show_conflict(request)
  local agent = request.kind == "agent_conflict"
  local choices = agent and { "keep my changes", "accept agent changes", "open manual diff" }
    or { "open external diff", "retry apply", "cancel" }
  vim.ui.select(choices, { prompt = "OpenCode " .. identity(request) }, function(choice)
    local runtime, job = context(request)
    if not runtime or not job or request.state == "closed" then
      return
    end
    if not choice or choice == "cancel" then
      close(request, "cancelled")
    elseif choice == "keep my changes" or choice == "accept agent changes" then
      require("opencode.apply").prefer(
        job,
        runtime,
        choice == "keep my changes" and "ours" or "theirs",
        function(ok, err)
          if not ok then
            retry_visible(request, err)
          end
        end
      )
    elseif choice == "open manual diff" then
      require("opencode.ui.diff").agent(request, runtime, job)
    elseif choice == "open external diff" then
      require("opencode.ui.diff").external(request, runtime, job)
    elseif choice == "retry apply" then
      if
        require("opencode.apply").retry(job, runtime, function(ok, err)
          if not ok then
            retry_visible(request, err)
          end
        end)
      then
        return
      end
      vim.schedule(function()
        M.show(request)
      end)
    else
      vim.schedule(function()
        M.show(request)
      end)
    end
  end)
end

local function answer_questions(request, index, answers)
  local questions = request.payload.questions or request.payload
  local question = questions[index]
  if not question then
    local runtime = context(request)
    submit(request, runtime.client:question_reply(request.request_id, answers))
    return
  end
  local selected = {}
  local function custom(next_step)
    vim.ui.input({ prompt = identity(request) .. ": " .. question.question .. ": " }, function(value)
      if value == nil then
        M.reject(request)
        return
      end
      if value ~= "" then
        table.insert(selected, value)
      end
      next_step()
    end)
  end
  local function finish()
    answers[index] = selected
    answer_questions(request, index + 1, answers)
  end
  local function choose_multiple(remaining)
    local choices = vim.deepcopy(remaining)
    table.insert(choices, { label = "Submit selections", submit = true })
    if question.custom then
      table.insert(choices, { label = "Type a custom answer", custom = true })
    end
    vim.ui.select(choices, {
      prompt = identity(request) .. ": " .. question.question,
      format_item = function(item)
        return item.description and (item.label .. " - " .. item.description) or item.label
      end,
    }, function(choice)
      if not choice then
        M.reject(request)
      elseif choice.submit then
        finish()
      elseif choice.custom then
        custom(function()
          choose_multiple(remaining)
        end)
      else
        table.insert(selected, choice.label)
        for i, option in ipairs(remaining) do
          if option == choice then
            table.remove(remaining, i)
            break
          end
        end
        choose_multiple(remaining)
      end
    end)
  end
  local options = vim.deepcopy(question.options or {})
  if question.multiple then
    choose_multiple(options)
  elseif #options == 0 then
    custom(finish)
  else
    if question.custom then
      table.insert(options, { label = "Type a custom answer", custom = true })
    end
    vim.ui.select(options, {
      prompt = identity(request) .. ": " .. question.question,
      format_item = function(item)
        return item.description and (item.label .. " - " .. item.description) or item.label
      end,
    }, function(choice)
      if not choice then
        M.reject(request)
      elseif choice.custom then
        custom(finish)
      else
        selected[1] = choice.label
        finish()
      end
    end)
  end
end

---Rejects a remote interaction through its canonical endpoint and waits for the matching SSE event.
---HTTP failure leaves the request visible and the Runtime prompt-locked for later reconciliation.
function M.reject(request)
  local runtime = context(request)
  local promise = request.kind == "question" and runtime.client:question_reject(request.request_id)
    or runtime.client:permission_reply(request.request_id, "reject")
  submit(request, promise)
end

---Shows one queue-owned native interaction and maps every close to explicit cancel or reject.
---Remote HTTP success only marks awaiting confirmation; matching SSE events own completion.
function M.show(request)
  if request.kind == "agent_conflict" or request.kind == "external_change" then
    show_conflict(request)
    return
  end
  if request.kind == "question" then
    answer_questions(request, 1, {})
    return
  end
  local actions = request.payload.actions or { "once", "always", "reject" }
  vim.ui.select(actions, { prompt = "Permission " .. identity(request) }, function(action)
    if not action or action == "reject" then
      M.reject(request)
      return
    end
    local runtime = context(request)
    submit(request, runtime.client:permission_reply(request.request_id, action))
  end)
end

return M
