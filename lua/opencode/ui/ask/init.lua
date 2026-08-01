local M = { contexts = {} }

local highlight_ns = vim.api.nvim_create_namespace("opencode_ask")

---Restores the captured editor only while it still shows the captured buffer.
---This avoids moving focus to a window that the user repurposed while the prompt was open.
local function restore_focus(context)
  if vim.api.nvim_win_is_valid(context.win) and vim.api.nvim_win_get_buf(context.win) == context.buf then
    vim.api.nvim_set_current_win(context.win)
  end
end

---Returns a bounded editor-relative size and position near the captured cursor.
---The prompt prefers space below the cursor, moves above it near the bottom, and remains visible at every editor edge.
local function geometry(context, snacks, line_count)
  local columns = math.max(vim.o.columns, 1)
  local lines = math.max(vim.o.lines - vim.o.cmdheight, 1)
  local max_width = math.max(1, math.min(100, columns - 2))
  local min_width = math.min(40, max_width)
  local width = snacks.width
  if type(width) ~= "number" then
    width = 72
  elseif width > 0 and width < 1 then
    width = math.floor(columns * width)
  end
  width = math.max(min_width, math.min(math.floor(width), max_width))

  local max_height = math.max(1, math.min(12, lines - 2))
  local min_height = math.min(3, max_height)
  local height = math.max(min_height, math.min(line_count, max_height))
  local screen = { row = 1, col = 1 }
  if vim.api.nvim_win_is_valid(context.win) and vim.api.nvim_win_get_buf(context.win) == context.buf then
    screen = vim.fn.screenpos(context.win, context.cursor[1], context.cursor[2] + 1)
  end
  local cursor_row = math.max(0, (screen.row or 1) - 1)
  local cursor_col = math.max(0, (screen.col or 1) - 1)
  local outer_height = height + 2
  local row = cursor_row + 1
  if row + outer_height > lines then
    row = cursor_row - outer_height
  end
  row = math.max(0, math.min(row, math.max(0, lines - outer_height)))
  local col = math.max(0, math.min(cursor_col, math.max(0, columns - width - 2)))
  return { width = width, height = height, row = row, col = col }
end

---Replaces prompt highlights with line-aware extmarks from the context renderer.
---Rendering the complete buffer after each text change keeps multiline placeholders aligned with their actual rows.
local function update_highlights(buf, context)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  for _, mark in ipairs(context:render(text).input:extmarks()) do
    vim.api.nvim_buf_set_extmark(buf, highlight_ns, mark.row - 1, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl_group,
    })
  end
end

---Opens a multiline Build or Plan editor and resolves with its text after a successful submit.
---An optional readiness Promise may settle while the editor is open; Enter queues one submit until it is ready, and an
---optional submit callback may return a Promise. Failed readiness or submit work leaves the editor intact for retry.
---@param default? string
---@param context table
---@param mode? "plan"|"build"
---@param workflow_opts? table
---@param readiness? Promise<any>
---@param submit? fun(text: string): Promise<any>|any
---@return Promise<string>
function M.ask(default, context, mode, workflow_opts, readiness, submit)
  local Promise = require("opencode.promise")
  local config = require("opencode.config")
  mode = mode or "build"
  local scope_kind = ""

  if mode == "build" then
    local text = table.concat(vim.api.nvim_buf_get_lines(context.buf, 0, -1, false), "\n")
    local scope = require("opencode.scope").resolve(context, { text = text }, workflow_opts and workflow_opts.scope)
    if scope then
      scope_kind = " | " .. scope.kind
      context.displayed_scope = {
        sha256 = vim.fn.sha256(text),
        kind = scope.kind,
        start_byte = scope.start_byte,
        end_byte = scope.end_byte,
      }
    else
      scope_kind = " | unsupported"
    end
  end

  local result, resolve, reject = Promise.with_resolvers()
  local ready = readiness == nil
  local readiness_failed = false
  local queued = false
  local submitting = false
  local settled = false
  local win

  local function set_status(message)
    if not win or not win:valid() then
      return
    end
    win.opts.footer = message and { { " " .. message .. " ", "DiagnosticInfo" } } or nil
    win:update()
  end

  local function fail(err, status)
    queued = false
    submitting = false
    local class = type(err) == "table" and err.error_class or "error"
    if type(class) ~= "string" or #class > 80 or not class:match("^[%w_-]+$") then
      class = "error"
    end
    set_status(status or (class .. "; press Enter to retry"))
    require("opencode.ui.notify").error(err)
  end

  local function finish(text)
    settled = true
    win:close()
    resolve(text)
  end

  local function dispatch()
    if settled or submitting or not win or not win:valid() then
      return
    end
    if not ready then
      if readiness_failed and submit then
        ready = true
      else
        queued = true
        set_status(readiness_failed and "OpenCode startup failed" or "Starting OpenCode")
        return
      end
    end
    local text = win:text()
    submitting = true
    set_status("Submitting")
    local submitted = submit
        and Promise.new(function(done, failed)
          local ok, value = pcall(submit, text)
          if ok then
            done(value)
          else
            failed(value)
          end
        end)
      or Promise.resolve(text)
    submitted
      :next(function()
        finish(text)
      end)
      :catch(fail)
  end

  local function cancel()
    if settled then
      return
    end
    settled = true
    win:close()
    reject({ error_class = "cancelled" })
  end

  ---Inserts one line break at the prompt cursor without relying on terminal keycode translation.
  ---Both Shift-Enter and Ctrl-j call this same operation so their behavior cannot drift.
  local function insert_newline()
    if not win or not win:valid() then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(win.win)
    vim.api.nvim_buf_set_text(win.buf, cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2], { "", "" })
    vim.api.nvim_win_set_cursor(win.win, { cursor[1] + 1, 0 })
  end

  local snacks = vim.tbl_deep_extend("force", {}, config.opts.ask.snacks.win or {})
  local user_on_buf = snacks.on_buf
  local user_on_win = snacks.on_win
  local user_on_close = snacks.on_close
  local initial = default or ""
  local dim = geometry(context, snacks, #vim.split(initial, "\n", { plain = true }))
  snacks.buf = nil
  snacks.file = nil
  snacks.text = initial
  snacks.title = string.format(
    "%s | %s | %s%s",
    mode == "build" and "Build" or "Plan",
    context.root,
    require("opencode.context.builtins").this(context),
    scope_kind
  )
  snacks.relative = "editor"
  snacks.position = "float"
  snacks.enter = true
  snacks.show = true
  snacks.focusable = true
  snacks.fixbuf = true
  snacks.border = snacks.border or "rounded"
  snacks.width = dim.width
  snacks.height = dim.height
  snacks.min_width = dim.width
  snacks.max_width = dim.width
  snacks.min_height = 1
  snacks.max_height = math.max(1, math.min(12, vim.o.lines - vim.o.cmdheight - 2))
  snacks.row = dim.row
  snacks.col = dim.col
  snacks.bo = vim.tbl_deep_extend("force", snacks.bo or {}, {
    buftype = "nofile",
    bufhidden = "wipe",
    swapfile = false,
    filetype = "opencode_ask",
  })
  snacks.wo = vim.tbl_deep_extend("force", snacks.wo or {}, { wrap = true, linebreak = true })
  snacks.keys = vim.tbl_deep_extend("force", snacks.keys or {}, {
    submit = {
      "<CR>",
      function()
        if vim.fn.pumvisible() == 1 then
          return "<C-y>"
        end
        vim.schedule(dispatch)
        return ""
      end,
      mode = "i",
      expr = true,
      desc = "Submit",
    },
    submit_normal = { "<CR>", dispatch, mode = "n", desc = "Submit" },
    newline = { "<S-CR>", insert_newline, mode = "i", desc = "New line" },
    newline_fallback = { "<C-j>", insert_newline, mode = "i", desc = "New line" },
    cancel = { "<Esc>", cancel, mode = { "i", "n" }, desc = "Cancel" },
  })
  snacks.on_buf = function(opened)
    M.contexts[opened.buf] = context
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = opened.augroup,
      buffer = opened.buf,
      callback = function()
        update_highlights(opened.buf, context)
        local next_dim = geometry(context, snacks, vim.api.nvim_buf_line_count(opened.buf))
        opened.opts.height = next_dim.height
        opened.opts.row = next_dim.row
        opened:update()
      end,
    })
    update_highlights(opened.buf, context)
    vim.lsp.start(require("opencode.ui.ask.cmp"), { bufnr = opened.buf })
    if user_on_buf then
      pcall(user_on_buf, opened)
    end
  end
  snacks.on_win = function(opened)
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    vim.api.nvim_win_set_cursor(opened.win, { #lines, #(lines[#lines] or "") })
    if user_on_win then
      pcall(user_on_win, opened)
    end
  end
  snacks.on_close = function(closed)
    M.contexts[closed.buf] = nil
    restore_focus(context)
    if user_on_close then
      pcall(user_on_close, closed)
    end
    if not settled then
      settled = true
      reject({ error_class = "cancelled" })
    end
  end

  win = require("snacks.win")(snacks)
  if readiness then
    set_status("Starting OpenCode")
    readiness
      :next(function()
        ready = true
        set_status(nil)
        if queued then
          dispatch()
        end
      end)
      :catch(function(err)
        ready = false
        readiness_failed = true
        fail(err)
      end)
  end
  vim.cmd.startinsert()
  return result
end

return M
