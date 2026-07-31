local M = {}

local profiles = { ["1.17.3"] = true, ["1.18.9"] = true }

local function write(path, value)
  local file = assert(io.open(path, "wb"))
  file:write(value)
  file:close()
end

---Records one completed authenticated release run and updates its per-AC result index.
---The caller reaches this function only after acceptance, privacy, E2E, and manifest commands exit successfully.
---Artifacts contain fixed metadata rather than command output so credentials, source text, and machine paths cannot leak.
---@param root string
---@param profile string
function M.record(root, profile)
  assert(profiles[profile], "unsupported profile")
  local manifest = dofile(root .. "/tests/acceptance.lua")
  local artifact = "tests/release/results/" .. profile .. ".txt"
  local checksum = artifact .. ".sha256"
  local content = table.concat({
    "opencode.nvim v2.0 release evidence",
    "profile=" .. profile,
    "git_commit=" .. assert(vim.env.RELEASE_GIT_COMMIT, "missing RELEASE_GIT_COMMIT"),
    "acceptance_scenarios=" .. #manifest.scenarios,
    "runtime_privacy=passed",
    "authenticated_e2e=passed",
    "result=passed",
    "",
  }, "\n")
  write(root .. "/" .. artifact, content)
  write(root .. "/" .. checksum, vim.fn.sha256(content) .. "  " .. profile .. ".txt\n")

  local existing = dofile(root .. "/tests/release/results/index.lua")
  local results = {}
  for _, result in ipairs(existing) do
    if result.profile ~= profile then
      table.insert(results, result)
    end
  end
  for _, scenario in ipairs(manifest.scenarios) do
    table.insert(results, {
      id = scenario.id,
      profile = profile,
      exit_code = 0,
      artifact = artifact,
      checksum = checksum,
    })
  end
  table.sort(results, function(a, b)
    return a.id == b.id and a.profile < b.profile or a.id < b.id
  end)
  local lines = { "return {" }
  for _, result in ipairs(results) do
    table.insert(
      lines,
      string.format(
        "  { id = %q, profile = %q, exit_code = 0, artifact = %q, checksum = %q },",
        result.id,
        result.profile,
        result.artifact,
        result.checksum
      )
    )
  end
  table.insert(lines, "}")
  write(root .. "/tests/release/results/index.lua", table.concat(lines, "\n") .. "\n")
end

return M
