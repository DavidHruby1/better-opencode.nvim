local M = {}

local function clean_text(value, fallback)
  if type(value) ~= "string" or value == "" then
    return fallback
  end
  local cleaned = vim.trim(value:gsub("[%c]", " "):gsub("%s+", " "))
  return cleaned ~= "" and cleaned or fallback
end

local function session_short_id(session)
  local id = clean_text(session.id, "unknown")
  return clean_text(session.short_id, id:sub(-8))
end

local function relative_directory(root, directory)
  directory = clean_text(directory, ".")
  local relative = vim.fs.relpath(root, directory)
  if relative == "" then
    return "."
  end
  return clean_text(relative, directory)
end

---Formats a Session timestamp for the picker row without assuming one OpenCode timestamp representation.
---Numeric values are treated as Unix seconds or milliseconds; string values stay readable and are shortened to a single
---line. This keeps the picker useful across the supported server profiles and older persisted metadata.
local function updated_text(session)
  local value = session.updated or session.activity
  if value == nil and type(session.time) == "table" then
    value = session.time.updated
  end
  local timestamp = type(value) == "number" and value or tonumber(value)
  if timestamp then
    if timestamp > 100000000000 then
      timestamp = timestamp / 1000
    end
    local ok, formatted = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(timestamp))
    if ok then
      return formatted
    end
  end
  return clean_text(value, "unknown")
end

---Returns a Session's current availability while preserving cached active or blocked states as non-deletable.
---Reusable rows are rechecked through the Session behavior home so new Jobs and claims cannot be selected from stale picker
---items; unknown values fail closed instead of making an unverified Session selectable.
local function availability(runtime, session)
  if session.availability == "active" or session.availability == "blocked" then
    return session.availability
  end
  local value = require("opencode.session").availability(runtime, session, session.remote_status)
  if value == "active" or value == "blocked" or value == "reusable" then
    return value
  end
  return "unavailable"
end

---Converts one verified Session into the searchable row and detail preview shown by Snacks picker.
---The row leads with the generated title and keeps the short ID as a secondary disambiguator; the preview repeats those
---facts with status, directory, update time, and the parent relationship.
local function session_item(runtime, session)
  local state = availability(runtime, session)
  local id = session_short_id(session)
  local title = clean_text(session.title, "Untitled")
  local directory = relative_directory(runtime.root, session.directory)
  local updated = updated_text(session)
  local parent = clean_text(session.parent_id, "-")
  if parent ~= "-" then
    parent = parent:sub(-8)
  end
  local remote_status = clean_text(session.remote_status, "idle")
  local text = string.format("[%s] %s  (%s)  %s  %s  parent: %s", state, title, id, directory, updated, parent)
  return {
    text = text,
    session = session,
    session_id = session.id,
    availability = state,
    short_id = id,
    title = title,
    directory = directory,
    updated = updated,
    parent = parent,
    preview = {
      text = table.concat({
        "Title: " .. title,
        "ID: " .. id,
        "Status: " .. state .. " (remote: " .. remote_status .. ")",
        "Updated: " .. updated,
        "Directory: " .. directory,
        "Parent: " .. parent,
      }, "\n"),
      ft = "text",
      loc = false,
    },
  }
end

---Renders a Session row with an explicit status color while putting the generated title before the short ID.
---All identity fields remain searchable by Snacks, so the ID still distinguishes sessions with the same title.
---@param item table
---@return table[]
local function format_session(item)
  local status_hl = item.availability == "reusable" and "DiagnosticOk"
    or item.availability == "active" and "DiagnosticWarn"
    or "DiagnosticError"
  return {
    { "[" .. item.availability .. "]", status_hl, field = "availability" },
    { " " },
    { item.title, "SnacksPickerFile", field = "title" },
    { "  " },
    { "(" .. item.short_id .. ")", "SnacksPickerLabel", field = "short_id" },
    { "  " },
    { item.directory, "SnacksPickerDir", field = "directory" },
    { "  " },
    { item.updated, "SnacksPickerTime", field = "updated" },
    { "  parent: " .. item.parent, "SnacksPickerComment", field = "parent" },
  }
end

---Restores the prior Session pointer only when this picker still owns the selected value.
---A later successful dispatch or another picker selection is left untouched.
local function restore_selection(runtime, selected_id, previous_id)
  if runtime.selected_session_id == selected_id then
    runtime.selected_session_id = previous_id
  end
end

---Opens the existing Build editor for a selected Session without capturing editor state again.
---Dirty-buffer preflight runs before the window opens, and submit sends the same captured Context through the normal
---Build prompt API. The previous pointer is restored if opening or cancelling this prompt does not dispatch successfully.
local function open_build_ask(runtime, context, opts, selected_id, previous_id)
  local Promise = require("opencode.promise")
  local ask_opts = vim.deepcopy(opts or {})
  ask_opts.mode = "build"
  ask_opts.new_session = false
  ask_opts.session_id = selected_id
  local dispatched = false
  local dispatch_result
  local flow = require("opencode.context.preflight").run(context):next(function()
    return require("opencode.ui.ask").ask(nil, context, "build", ask_opts, nil, function(text)
      return require("opencode.api.prompt").prompt(text, context, ask_opts):next(function(result)
        dispatched = true
        dispatch_result = result
        return result
      end)
    end)
  end)
  flow = flow:next(function(ask_result)
    return dispatched and dispatch_result or ask_result
  end)
  return flow:catch(function(err)
    restore_selection(runtime, selected_id, previous_id)
    return Promise.reject(err)
  end)
end

---Converts fresh verified inventory entries into the rows consumed by the Snacks picker.
---The same conversion is used after deletion so stale rows cannot remain searchable or reusable.
local function inventory_items(runtime, inventory)
  local items = {}
  for _, session in ipairs(inventory or {}) do
    if type(session) == "table" and type(session.id) == "string" then
      table.insert(items, session_item(runtime, session))
    end
  end
  return items
end

---Refreshes an open picker from a new verified inventory response without changing selection state first.
---Inventory removes only confirmed inactive absences; refresh failures leave the existing picker visible and report the error.
local function refresh_picker(runtime, picker)
  local Promise = require("opencode.promise")
  return require("opencode.session")
    .inventory(runtime)
    :next(function(inventory)
      picker.opts = picker.opts or {}
      picker.opts.items = inventory_items(runtime, inventory)
      if not picker.closed then
        picker:refresh()
      end
    end)
    :catch(function(err)
      require("opencode.ui.notify").error(err)
      return Promise.resolve()
    end)
end

---Confirms deletion with the Session identity and its parent-child warning before any remote request starts.
---Cancel or an unavailable row leaves the picker open; confirmation performs a fresh verified revalidation before DELETE.
local function delete_session(runtime, picker, item)
  local Promise = require("opencode.promise")
  local session_module = require("opencode.session")
  local selected = item and item.session
  if type(selected) ~= "table" or type(selected.id) ~= "string" then
    require("opencode.ui.notify").warn("session_verification")
    return false
  end

  local state = availability(runtime, selected)
  local error_class = runtime.reconciliation_blocked and "reconciliation_blocked"
    or state == "active" and "session_active"
    or state == "blocked" and "session_busy"
    or state ~= "reusable" and "session_verification"
  if error_class then
    require("opencode.ui.notify").warn(error_class)
    return false
  end

  local title = clean_text(selected.title, "Untitled")
  local short_id = session_short_id(selected)
  local confirmation = table.concat({
    "Delete this OpenCode session?",
    "Title: " .. title,
    "Short ID: " .. short_id,
    "Root: " .. runtime.root,
    "Warning: deleting a parent session may also delete its child sessions.",
  }, "\n")
  vim.ui.select({ "Delete session", "Cancel" }, { prompt = confirmation }, function(choice)
    if choice ~= "Delete session" then
      return
    end
    local claim
    local ok, flow = pcall(function()
      return session_module
        .inventory(runtime)
        :next(function(inventory)
          local current
          for _, candidate in ipairs(inventory or {}) do
            if candidate.id == selected.id then
              current = candidate
              break
            end
          end
          if not current then
            return Promise.reject({ error_class = "http", status = 404, endpoint = "/session/" .. selected.id })
          end
          local current_state = availability(runtime, current)
          if runtime.reconciliation_blocked or current_state ~= "reusable" then
            return Promise.reject({
              error_class = current_state == "active" and "session_active" or "session_busy",
            })
          end
          local claim_error
          claim, claim_error = session_module.claim(runtime, selected.id)
          if not claim then
            return Promise.reject({ error_class = claim_error or "session_busy" })
          end
          return session_module.revalidate(runtime, selected.id, true)
        end)
        :next(function()
          if runtime.reconciliation_blocked then
            return Promise.reject({ error_class = "reconciliation_blocked" })
          end
          return runtime.client:delete_session(selected.id)
        end)
    end)
    if not ok then
      session_module.release_claim(runtime, selected.id, claim)
      require("opencode.ui.notify").error(flow)
      return
    end
    flow
      :next(function()
        session_module.release_claim(runtime, selected.id, claim)
        runtime.sessions[selected.id] = nil
        if runtime.selected_session_id == selected.id then
          runtime.selected_session_id = nil
        end
        return refresh_picker(runtime, picker)
      end)
      :catch(function(err)
        session_module.release_claim(runtime, selected.id, claim)
        if type(err) == "table" and err.status == 404 then
          return refresh_picker(runtime, picker)
        end
        require("opencode.ui.notify").error(err)
      end)
  end)
  return false
end

---Loads verified managed Sessions, presents reusable and unavailable rows in a Snacks picker, and starts Build with the
---captured Context after selection. Inventory owns metadata, root, and detail verification; active rows stay visible but
---their confirm action warns and leaves the picker open instead of reusing them. Delete revalidates before DELETE and
---refreshes the same picker only after a remote result.
---@param runtime table
---@param context table
---@param opts? opencode.PromptOpts
---@return Promise<any>
function M.open(runtime, context, opts)
  local Promise = require("opencode.promise")
  local session_module = require("opencode.session")
  return session_module.inventory(runtime):next(function(inventory)
    local items = inventory_items(runtime, inventory)
    if #items == 0 then
      return Promise.reject({ error_class = "missing_session" })
    end

    local result, resolve, reject = Promise.with_resolvers()
    local completed = false

    ---Rejects picker cancellation unless a reusable selection already transferred control to the Build editor.
    local function on_close()
      if not completed then
        completed = true
        reject({ error_class = "cancelled" })
      end
    end

    ---Accepts only a reusable inventory row and opens Build with the original Context.
    ---Active or blocked rows remain selectable in the list for visibility but never fall through to prompt reuse.
    local function confirm(picker, item)
      local selected = item and item.session
      if type(selected) ~= "table" then
        require("opencode.ui.notify").warn("session_verification")
        return false
      end
      local state = availability(runtime, selected)
      if state ~= "reusable" then
        local error_class = state == "active" and "session_active"
          or state == "blocked" and "session_busy"
          or "session_verification"
        require("opencode.ui.notify").warn(error_class)
        return false
      end

      local previous_id = runtime.selected_session_id
      completed = true
      picker:close()
      vim.schedule(function()
        local ok, flow = pcall(open_build_ask, runtime, context, opts, selected.id, previous_id)
        if not ok then
          restore_selection(runtime, selected.id, previous_id)
          reject(flow)
          return
        end
        flow:next(resolve):catch(reject)
      end)
      return true
    end

    local picker = require("snacks").picker({
      source = "opencode_session",
      items = items,
      title = "OpenCode Sessions",
      prompt = "Session ",
      preview = "preview",
      auto_confirm = false,
      format = format_session,
      actions = {
        confirm = confirm,
        delete_session = function(current_picker, item)
          return delete_session(runtime, current_picker, item)
        end,
      },
      win = {
        input = {
          keys = {
            ["d"] = { "delete_session", mode = { "n", "i" }, desc = "Delete session" },
            ["<C-d>"] = { "delete_session", mode = { "n", "i" }, desc = "Delete session" },
          },
        },
        list = {
          keys = {
            ["d"] = { "delete_session", mode = { "n", "i" }, desc = "Delete session" },
            ["<C-d>"] = { "delete_session", mode = { "n", "i" }, desc = "Delete session" },
          },
        },
      },
      on_close = on_close,
    })
    if not picker and not completed then
      completed = true
      reject({ error_class = "cancelled" })
    end
    return result
  end)
end

return M
