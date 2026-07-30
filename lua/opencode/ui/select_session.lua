local M = {}

---Shows verified managed Sessions and switches only the Runtime's TUI transcript selection.
---The selection is committed after the Runtime-local API succeeds; closing the picker changes nothing.
---@param runtime table
function M.show(runtime)
  require("opencode.session").inventory(runtime):next(function(sessions)
    vim.ui.select(sessions, {
      prompt = "OpenCode sessions",
      format_item = function(session)
        return string.format(
          "%s | %s | %s | %s | %s",
          vim.fs.basename(runtime.root),
          session.title or "Untitled",
          session.short_id,
          session.last_mode or "unknown",
          session.availability
        )
      end,
    }, function(session)
      if not session then
        return
      end
      require("opencode.session").select(runtime, session.id):next(function()
        runtime.sidebar:show()
      end):catch(function()
        vim.notify("OpenCode: session_select", vim.log.levels.ERROR)
      end)
    end)
  end):catch(function()
    vim.notify("OpenCode: session_inventory", vim.log.levels.ERROR)
  end)
end

return M
