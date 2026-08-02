local M = { contexts = {} }

local highlight_ns = vim.api.nvim_create_namespace("opencode_ask")

---Restores the captured editor only while it still shows the captured buffer.
---This avoids moving focus to a window that the user repurposed while the prompt was open.
local function restore_focus(context)
  if vim.api.nvim_win_is_valid(context.win) and vim.api.nvim_win_get_buf(context.win) == context.buf then
    vim.api.nvim_set_current_win(context.win)
  end
end

---Counts content rows after display-width wrapping while preserving every explicit newline.
---Each physical line occupies at least one row, so an empty prompt stays editable and long input can grow the float.
local function display_rows(text, width)
  local rows = 0
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  return math.max(1, rows)
end

---Returns a bounded editor-relative size and position above the captured cursor.
---The width stays within the configured and available limits, while height follows display-width wrapping and explicit
---newlines. Keeping the float clamped leaves the prompt usable when the cursor is near an editor edge.
local function geometry(context, snacks, text)
  local columns = math.max(vim.o.columns, 1)
  local lines = math.max(vim.o.lines - vim.o.cmdheight, 1)
  local screen_width = math.max(1, columns - 2)
  local configured_width = snacks.width
  if type(configured_width) ~= "number" or configured_width <= 0 then
    configured_width = 60
  elseif configured_width < 1 then
    configured_width = math.floor(columns * configured_width)
  end
  local min_width = type(snacks.min_width) == "number" and snacks.min_width or math.max(60, configured_width)
  local max_width = screen_width
  if type(snacks.max_width) == "number" then
    max_width = math.min(max_width, snacks.max_width)
  end
  max_width = math.max(1, max_width)
  min_width = math.max(1, math.min(math.floor(min_width), max_width))

  local width = math.max(min_width, math.min(math.floor(configured_width), max_width))

  local max_height = math.max(1, math.min(12, lines - 2))
  local content_width = math.max(1, width - 5)
  local height = math.max(1, math.min(display_rows(text, content_width), max_height))
  local screen = { row = 1, col = 1 }
  if vim.api.nvim_win_is_valid(context.win) and vim.api.nvim_win_get_buf(context.win) == context.buf then
    screen = vim.fn.screenpos(context.win, context.cursor[1], context.cursor[2] + 1)
  end
  local cursor_row = math.max(0, (screen.row or 1) - 1)
  local cursor_col = math.max(0, (screen.col or 1) - 1)
  local outer_height = height + 2
  local row = cursor_row - outer_height
  row = math.max(0, math.min(row, math.max(0, lines - outer_height)))
  local col = math.max(0, math.min(cursor_col, math.max(0, columns - width - 2)))
  return {
    width = width,
    min_width = min_width,
    max_width = max_width,
    height = height,
    row = row,
    col = col,
  }
end

---Replaces prompt highlights with line-aware extmarks from the context renderer.
---Only placeholder matching runs on each text change, so providers and referenced-buffer tracking stay untouched until render is needed.
local function update_highlights(buf, context)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  for _, mark in ipairs(context:input(text):extmarks()) do
    vim.api.nvim_buf_set_extmark(buf, highlight_ns, mark.row - 1, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl_group,
      strict = false,
    })
  end
end

---Opens a Build editor with one content row initially and resolves with its text after a successful submit.
---Visual wrapping and explicit newlines grow the editor; <CR> submits or accepts completion, while <S-CR> and <C-j>
---insert newlines.
---An optional readiness Promise may settle while the editor is open; Enter queues one submit until it is ready, and an
---optional submit callback may return a Promise. Failed readiness or submit work leaves the editor intact for retry.
---@param default? string
---@param context table
---@param _mode? "build" Compatibility argument for existing callers; the editor always uses Build.
---@param workflow_opts? table
---@param readiness? Promise<any>
---@param submit? fun(text: string): Promise<any>|any
---@return Promise<string>
function M.ask(default, context, _mode, workflow_opts, readiness, submit)
  local Promise = require("opencode.promise")
  local config = require("opencode.config")
  local scope_kind = "unsupported"

  local text = table.concat(vim.api.nvim_buf_get_lines(context.buf, 0, -1, false), "\n")
  local scope = require("opencode.scope").resolve(context, { text = text }, workflow_opts and workflow_opts.scope)
  if scope then
    scope_kind = scope.kind
    context.displayed_scope = {
      sha256 = vim.fn.sha256(text),
      kind = scope.kind,
      start_byte = scope.start_byte,
      end_byte = scope.end_byte,
    }
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
    win.opts.footer = message and { { " " .. message .. " ", "SnacksInputTitle" } } or nil
    win:update()
  end

  local function fail(err, status)
    queued = false
    submitting = false
    local class = type(err) == "table" and err.error_class or "error"
    if type(class) ~= "string" or #class > 80 or not class:match("^[%w_-]+$") then
      class = "error"
    end
    set_status(status or ("Error: " .. class))
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
        set_status("Starting")
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

  ---Inserts one real line break at the prompt cursor without relying on terminal keycode translation.
  ---<S-CR> calls this operation and <C-j> remains its fallback, so neither newline key submits the prompt.
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
  local geometry_opts = {
    width = snacks.width,
    min_width = snacks.min_width,
    max_width = snacks.max_width,
  }
  local dim = geometry(context, geometry_opts, "")
  ---Recomputes the float bounds from current prompt text and applies the same edge clamps used at open.
  ---Text changes can add wrapped rows or explicit newlines, so the prompt grows without allowing its window to leave the editor.
  local function update_geometry(opened)
    if not opened:valid() then
      return
    end
    local next_dim = geometry(context, geometry_opts, opened:text())
    opened.opts.width = next_dim.width
    opened.opts.min_width = next_dim.min_width
    opened.opts.max_width = next_dim.max_width
    opened.opts.height = next_dim.height
    opened.opts.row = next_dim.row
    opened.opts.col = next_dim.col
    opened:update()
  end
  snacks.buf = nil
  snacks.file = nil
  snacks.text = initial
  local root_name = vim.fs.basename(context.root)
  snacks.title = string.format(" Build | %s | %s ", root_name, scope_kind)
  snacks.footer = nil
  snacks.relative = "editor"
  snacks.position = "float"
  snacks.enter = true
  snacks.show = true
  snacks.focusable = true
  snacks.fixbuf = true
  snacks.border = snacks.border or "rounded"
  snacks.width = dim.width
  snacks.min_width = dim.min_width
  snacks.max_width = dim.max_width
  snacks.height = dim.height
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
  snacks.wo = vim.tbl_deep_extend(
    "force",
    {
      winhighlight = "NormalFloat:SnacksInputNormal,FloatBorder:SnacksInputBorder,FloatTitle:SnacksInputTitle",
    },
    snacks.wo or {},
    {
      statuscolumn = " %#SnacksInputIcon#󰚩 ",
      wrap = true,
      linebreak = true,
    }
  )
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
    newline_shift = { "<S-CR>", insert_newline, mode = "i", desc = "New line" },
    newline = { "<C-j>", insert_newline, mode = "i", desc = "New line" },
    cancel = { "<Esc>", cancel, mode = { "i", "n" }, desc = "Cancel" },
  })
  snacks.on_buf = function(opened)
    M.contexts[opened.buf] = context
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = opened.augroup,
      buffer = opened.buf,
      callback = function()
        update_highlights(opened.buf, context)
        update_geometry(opened)
      end,
    })
    update_highlights(opened.buf, context)
    vim.lsp.start(require("opencode.ui.ask.cmp"), { bufnr = opened.buf })
    if user_on_buf then
      pcall(user_on_buf, opened)
    end
    update_geometry(opened)
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
    set_status("Starting")
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
