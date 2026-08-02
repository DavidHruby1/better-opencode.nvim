---@type table<vim.lsp.protocol.Method, fun(params: table, callback:fun(err: lsp.ResponseError?, result: any))>
local handlers = {}
local ms = vim.lsp.protocol.Methods

---@param params lsp.InitializeParams
---@param callback fun(err?: lsp.ResponseError, result: lsp.InitializeResult)
handlers[ms.initialize] = function(params, callback)
  callback(nil, {
    capabilities = {
      completionProvider = {
        resolveProvider = true,
      },
    },
    serverInfo = {
      name = "opencode_ask_cmp",
    },
  })
end

---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result: lsp.CompletionItem[])
handlers[ms.textDocument_completion] = function(params, callback)
  local items = {}
  local config = require("opencode.config")

  for placeholder, _ in pairs(config.opts.contexts or {}) do
    ---@type lsp.CompletionItem
    local item = {
      label = placeholder,
      filterText = placeholder,
      insertText = placeholder,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
      kind = vim.lsp.protocol.CompletionItemKind.Variable,
    }
    table.insert(items, item)
  end

  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local context = require("opencode.ui.ask").contexts[bufnr]
  local runtime = context and context.runtime
  local agents = runtime and runtime.agents or {}
  for _, agent in ipairs(agents) do
    local label = "@" .. agent.name
    ---@type lsp.CompletionItem
    local item = {
      label = label,
      filterText = label,
      insertText = label,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
      kind = vim.lsp.protocol.CompletionItemKind.Property,
      documentation = {
        kind = "markdown",
        value = "```\n" .. (agent.description or "Agent") .. "\n```",
      },
    }
    table.insert(items, item)
  end

  callback(nil, items)
end

---@param params lsp.CompletionItem
---@param callback fun(err?: lsp.ResponseError, result: lsp.CompletionItem)
handlers[ms.completionItem_resolve] = function(params, callback)
  local item = vim.deepcopy(params)
  local context = require("opencode.ui.ask").contexts[vim.api.nvim_get_current_buf()]
  if not item.documentation and context then
    local rendered = context:preview(item.label)
    -- Highlights won't match other locations, but there's no general way to control them.
    -- Would have to support each completion plugin separately.
    -- Markdown code blocks to preserve formatting.
    -- `blink.cmp` at least seems to render the doc window as markdown even when the kind is plaintext,
    -- and then things like `~` in consecutive filepaths become strikethroughs.
    -- Or matching `[]` disappears because it's interpreted as a markdown link with an empty URL.
    item.documentation = {
      kind = "plaintext",
      value = rendered.output:plaintext(),
    }
  end

  callback(nil, item)
end

---An in-process LSP that provides completions for context placeholders and server agents.
---@type vim.lsp.Config
return {
  name = "opencode_ask_cmp",
  -- The editor starts this config directly so completion stays bound to its captured Context.
  -- It lives under `lua/` so normal module resolution can find it without global LSP configuration.
  filetypes = { "opencode_ask" },
  cmd = function(dispatchers, config)
    return {
      request = function(method, params, callback)
        if handlers[method] then
          handlers[method](params, callback)
        end
      end,
      notify = function() end,
      is_closing = function()
        return false
      end,
      terminate = function() end,
    }
  end,
}
