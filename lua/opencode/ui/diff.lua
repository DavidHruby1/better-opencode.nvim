local M = {}

local function scratch(name, text, editable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "opencode://" .. name)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].undofile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].modifiable = editable
  return buf
end

local function close_all(owner)
  if owner.closing then
    return
  end
  owner.closing = true
  for _, buf in ipairs(owner.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  if owner.tab and vim.api.nvim_tabpage_is_valid(owner.tab) then
    vim.api.nvim_set_current_tabpage(owner.source_tab)
    pcall(vim.api.nvim_tabpage_close, owner.tab, true)
  end
end

local function cancel(owner)
  close_all(owner)
  if owner.job.state == "conflict" then
    require("opencode.job").transition(owner.job, "cancelled", {
      session = owner.runtime.sessions[owner.job.session_id],
    })
  end
  require("opencode.interaction").complete_current(owner.request.id)
end

local function watch(owner)
  local group = vim.api.nvim_create_augroup("OpencodeDiff" .. owner.request.id, { clear = true })
  for _, buf in ipairs(owner.buffers) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      once = true,
      callback = function()
        if not owner.closing then
          cancel(owner)
        end
      end,
    })
  end
end

---Opens Job-local Base/Ours/Theirs/result buffers without displaying or editing the source buffer.
---The result starts from diff3 output; confirm alone sends it through the shared stale-checked apply path.
function M.agent(request, runtime, job)
  local payload = job.conflict_payload
  local owner = {
    request = request,
    runtime = runtime,
    job = job,
    source_tab = vim.api.nvim_get_current_tabpage(),
    buffers = {},
  }
  require("opencode.merge")
    .run(payload.base.text, payload.ours, payload.theirs)
    :next(function(merge)
      local result = merge.text or payload.ours
      owner.buffers = {
        scratch(request.id .. "/Base", payload.base.text, false),
        scratch(request.id .. "/Ours", payload.ours, false),
        scratch(request.id .. "/Theirs", payload.theirs, false),
        scratch(request.id .. "/Result", result, true),
      }
      vim.cmd.tabnew()
      owner.tab = vim.api.nvim_get_current_tabpage()
      vim.api.nvim_win_set_buf(0, owner.buffers[1])
      for i = 2, 4 do
        vim.cmd(i == 3 and "belowright split" or "belowright vsplit")
        vim.api.nvim_win_set_buf(0, owner.buffers[i])
        vim.cmd.diffthis()
      end
      watch(owner)
      local result_buf = owner.buffers[4]
      vim.keymap.set("n", "<CR>", function()
        local text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
        require("opencode.apply").manual(job, runtime, text, function(ok, err)
          if ok then
            close_all(owner)
          else
            require("opencode.ui.notify").warn(err)
          end
        end)
      end, { buffer = result_buf })
      vim.keymap.set("n", "q", function()
        cancel(owner)
      end, { buffer = result_buf })
    end)
    :catch(function()
      cancel(owner)
    end)
end

---Opens a read-only comparison of current buffer Ours and fresh disk text.
---Closing either scratch buffer returns to the still-open external conflict dialog without reloading source.
function M.external(request, runtime, job)
  local raw = require("opencode.snapshot").read_raw(job.path)
  local disk = raw and require("opencode.snapshot").decode_disk(raw, job.base)
  if not disk then
    return
  end
  local ours = table.concat(vim.api.nvim_buf_get_lines(job.buffer, 0, -1, false), "\n")
  vim.cmd.tabnew()
  local tab = vim.api.nvim_get_current_tabpage()
  local buffers = { scratch(request.id .. "/Buffer", ours, false), scratch(request.id .. "/Disk", disk, false) }
  vim.api.nvim_win_set_buf(0, buffers[1])
  vim.cmd.diffthis()
  vim.cmd.vsplit()
  vim.api.nvim_win_set_buf(0, buffers[2])
  vim.cmd.diffthis()
  for _, buf in ipairs(buffers) do
    vim.keymap.set("n", "q", function()
      for _, owned in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(owned) then
          vim.api.nvim_buf_delete(owned, { force = true })
        end
      end
      pcall(vim.api.nvim_tabpage_close, tab, true)
      vim.schedule(function()
        require("opencode.ui.dialog").show(request)
      end)
    end, { buffer = buf })
  end
end

return M
