local M = {}

---Returns every active Job in a Runtime without consulting or changing transcript selection.
---Rows contain only privacy-safe identity and state metadata for status UI callers.
---@param runtime table
---@return table[]
function M.jobs(runtime)
  local rows = {}
  for _, job in pairs(runtime.jobs) do
    if not require("opencode.job").terminal(job.state) then
      local session = runtime.sessions[job.session_id]
      table.insert(rows, {
        root = vim.fs.basename(runtime.root),
        session = session and session.short_id or job.session_id:sub(-8),
        job = job.user_message_id:sub(-8),
        mode = job.mode,
        state = job.state,
      })
    end
  end
  table.sort(rows, function(a, b)
    return a.job < b.job
  end)
  return rows
end

return M
