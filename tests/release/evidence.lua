local M = {}

local function rooted(root, path)
  return path:sub(1, 1) == "/" and path or root .. "/" .. path:gsub("^%./", "")
end

local function safe_reference(value)
  return type(value) == "string"
    and value ~= ""
    and not value:match("^/")
    and not value:match("%.%./")
    and not value:find("HOME", 1, true)
    and value
end

local function result_map(results)
  local map = {}
  for _, result in ipairs(results or {}) do
    if result.id and result.profile then
      map[result.id .. ":" .. result.profile] = result
    end
  end
  return map
end

local function result_status(result, scenario)
  if not result then
    return "FAIL missing result artifact"
  end
  if result.exit_code ~= 0 then
    return "FAIL exit code " .. tostring(result.exit_code)
  end
  if not safe_reference(result.artifact) or not safe_reference(result.checksum) then
    return "FAIL missing safe artifact/checksum"
  end
  if scenario.protocol and (result.manual ~= true or result.protocol_complete ~= true) then
    return "FAIL incomplete manual protocol"
  end
  return "PASS"
end

---Generates a release report from explicit result artifacts and refuses to claim PASS for missing evidence.
---Each acceptance ID is rendered with both exact OpenCode profiles and only repository-relative artifact references.
---@param root string
---@param results_path string
---@param output_path string
---@return boolean
function M.generate(root, results_path, output_path)
  local manifest = dofile(root .. "/tests/acceptance.lua")
  local results = dofile(rooted(root, results_path))
  local by_key = result_map(results)
  local lines = {
    "# v2.0 Acceptance Evidence",
    "",
    "Generated from `tests/acceptance.lua` and explicit result artifacts.",
    "",
    "Overall: **FAIL** until every required result has exit code `0`, a safe artifact/checksum, both exact profiles, and complete P2 protocols.",
    "",
    "| AC ID | Priority | Owner | 1.17.3 | 1.18.9 | Test/protocol |",
    "|---|---|---|---|---|---|",
  }
  local overall = true
  for _, scenario in ipairs(manifest.scenarios) do
    local statuses = {}
    for _, profile in ipairs(manifest.profiles) do
      statuses[profile] = result_status(by_key[scenario.id .. ":" .. profile], scenario)
      overall = overall and statuses[profile] == "PASS"
    end
    local evidence = scenario.protocol or scenario.test
    table.insert(
      lines,
      string.format(
        "| `%s` | %s | %s | %s | %s | `%s` |",
        scenario.id,
        scenario.priority,
        scenario.owner,
        statuses["1.17.3"],
        statuses["1.18.9"],
        evidence
      )
    )
  end
  if overall then
    lines[5] = "Overall: **PASS**."
  end
  table.insert(lines, "")
  table.insert(lines, "## Negative assertions")
  for _, assertion in ipairs({
    "no source disk write",
    "no stale apply",
    "no cross-Job or cross-root event",
    "no unauthorized execution",
    "no foreign process termination",
    "no Ours loss",
    "no whole-buffer replacement or reload",
    "one undo",
  }) do
    table.insert(lines, "- " .. assertion .. ": evidence must be linked by the owning acceptance result.")
  end
  local file = assert(io.open(rooted(root, output_path), "w"))
  file:write(table.concat(lines, "\n") .. "\n")
  file:close()
  return overall
end

return M
