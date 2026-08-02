local M = {}

---Removes commas before closing arrays or objects while preserving every byte inside JSON strings.
---Comments have already been removed, so lexical quote tracking and whitespace lookahead are sufficient here.
local function strip_trailing_commas(input)
  local out, i, quoted, escaped = {}, 1, false, false
  while i <= #input do
    local c = input:sub(i, i)
    if quoted then
      table.insert(out, c)
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        quoted = false
      end
    elseif c == '"' then
      quoted = true
      table.insert(out, c)
    elseif c == "," then
      local following = input:sub(i + 1):match("^%s*([}%]])")
      if not following then
        table.insert(out, c)
      end
    else
      table.insert(out, c)
    end
    i = i + 1
  end
  return table.concat(out)
end

---Removes JSONC comments and trailing commas without changing string content.
---A small state machine is used because pattern replacement would corrupt URLs and escaped quotes.
---@param input string
---@return string
function M.strip_jsonc(input)
  local out, i, quoted, escaped = {}, 1, false, false
  while i <= #input do
    local c, nextc = input:sub(i, i), input:sub(i + 1, i + 1)
    if quoted then
      table.insert(out, c)
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        quoted = false
      end
      i = i + 1
    elseif c == '"' then
      quoted = true
      table.insert(out, c)
      i = i + 1
    elseif c == "/" and nextc == "/" then
      i = (input:find("\n", i + 2, true) or (#input + 1))
    elseif c == "/" and nextc == "*" then
      local close = input:find("*/", i + 2, true)
      i = close and close + 2 or (#input + 1)
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return strip_trailing_commas(table.concat(out))
end

---Decodes passive JSON or JSONC config and rejects malformed input.
---@param text string
---@return table?
---@return string?
function M.decode(text)
  local ok, value = pcall(vim.json.decode, M.strip_jsonc(text))
  if not ok or type(value) ~= "table" then
    return nil, "config_parse"
  end
  return value
end

---Checks singular and plural tool fields against an optional allowed-tool set.
---Passive scans omit the set and reject every configured tool; effective config checks may pass profile tools so known
---or disabled entries remain valid. Plugins and MCPs are left to OpenCode because they do not extend the proposal tool
---boundary.
---@param config table
---@param allowed_tools? table<string, boolean>
---@return boolean
---@return string?
function M.validate(config, allowed_tools)
  if type(config) ~= "table" then
    return false, "custom_tool"
  end
  for _, field in ipairs({ "tool", "tools" }) do
    local tools = config[field]
    if tools ~= nil then
      if type(tools) ~= "table" then
        return false, "custom_tool"
      end
      if not allowed_tools and next(tools) then
        return false, "custom_tool"
      end
      for name, enabled in pairs(tools) do
        if allowed_tools and enabled ~= false and not allowed_tools[name] then
          return false, "custom_tool"
        end
      end
    end
  end
  return true
end

local function config_files(root)
  local home = vim.uv.os_homedir()
  local config_home = vim.env.XDG_CONFIG_HOME or (home .. "/.config")
  local files = {
    config_home .. "/opencode/opencode.json",
    config_home .. "/opencode/opencode.jsonc",
    home .. "/.opencode/opencode.json",
    home .. "/.opencode/opencode.jsonc",
    root .. "/opencode.json",
    root .. "/opencode.jsonc",
    root .. "/.opencode/opencode.json",
    root .. "/.opencode/opencode.jsonc",
  }
  if vim.env.OPENCODE_CONFIG then
    table.insert(files, vim.env.OPENCODE_CONFIG)
  end
  if vim.env.OPENCODE_CONFIG_DIR then
    table.insert(files, vim.env.OPENCODE_CONFIG_DIR .. "/opencode.json")
    table.insert(files, vim.env.OPENCODE_CONFIG_DIR .. "/opencode.jsonc")
  end
  if vim.env.OPENCODE_CONFIG_CONTENT then
    local config, err = M.decode(vim.env.OPENCODE_CONFIG_CONTENT)
    if not config then
      return nil, err
    end
    local ok, reason = M.validate(config)
    if not ok then
      return nil, reason
    end
  end
  return files
end

---Lists every documented directory where OpenCode can discover custom tools.
---Plugin directories are ignored because only tools extend the proposal boundary.
local function extension_dirs(root)
  local home = vim.uv.os_homedir()
  local config_home = vim.env.XDG_CONFIG_HOME or (home .. "/.config")
  local roots = { config_home .. "/opencode", home .. "/.opencode", root .. "/.opencode" }
  if vim.env.OPENCODE_CONFIG_DIR then
    table.insert(roots, vim.env.OPENCODE_CONFIG_DIR)
  end
  local dirs = {}
  for _, base in ipairs(roots) do
    for _, name in ipairs({ "tool", "tools" }) do
      table.insert(dirs, base .. "/" .. name)
    end
  end
  return dirs
end

---Passively scans documented config files and custom tool directories.
---It parses config without loading plugins or MCPs and rejects tools before the owned server starts.
---@param root string
---@return boolean
---@return string?
function M.scan(root)
  local files, err = config_files(root)
  if not files then
    return false, err
  end
  for _, file in ipairs(files) do
    if vim.uv.fs_stat(file) then
      local config, decode_err = M.decode(table.concat(vim.fn.readfile(file), "\n"))
      if not config then
        return false, decode_err
      end
      local ok, reason = M.validate(config)
      if not ok then
        return false, reason
      end
    end
  end
  for _, dir in ipairs(extension_dirs(root)) do
    local handle = vim.uv.fs_scandir(dir)
    if handle and vim.uv.fs_scandir_next(handle) then
      return false, "custom_tool"
    end
  end
  return true
end

return M
