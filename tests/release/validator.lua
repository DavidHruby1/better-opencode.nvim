local M = {}

local function read(path)
  local file = assert(io.open(path, "r"))
  local value = file:read("*a")
  file:close()
  return value
end

local function exists(path)
  local file = io.open(path, "r")
  if not file then
    return false
  end
  file:close()
  return true
end

local function acceptance_document(root)
  local scenarios, ids, current, priority = {}, {}, nil, nil
  for line in read(root .. "/docs/ACCEPTANCE.md"):gmatch("[^\n]+") do
    local id = line:match("^### (AC%-%u+%-%d+):")
    if id then
      if current then
        scenarios[current] = priority
      end
      table.insert(ids, id)
      current, priority = id, nil
    end
    local found = line:match("^%*%*Priorita:%*%*%s*(P%d)")
    if found then
      priority = found
    end
  end
  if current then
    scenarios[current] = priority
  end
  return scenarios, ids
end

---Validates manifest completeness against the authoritative acceptance document.
---It rejects missing or duplicate IDs, owner drift, missing P0/P1 commands, and unsupported P2 evidence shapes.
---@param root string
---@return table
function M.validate(root)
  local manifest = dofile(root .. "/tests/acceptance.lua")
  local document, document_ids = acceptance_document(root)
  local errors, seen = {}, {}
  local document_seen = {}
  for _, id in ipairs(document_ids) do
    if document_seen[id] then
      table.insert(errors, "duplicate document ID: " .. id)
    end
    document_seen[id] = true
  end
  for id, priority in pairs(document) do
    if seen[id] then
      table.insert(errors, "duplicate document ID: " .. id)
    end
    seen[id] = false
    if not priority then
      table.insert(errors, "missing priority: " .. id)
    end
  end
  for _, scenario in ipairs(manifest.scenarios or {}) do
    if seen[scenario.id] == nil then
      table.insert(errors, "unknown manifest ID: " .. tostring(scenario.id))
    elseif seen[scenario.id] then
      table.insert(errors, "duplicate manifest ID: " .. scenario.id)
    else
      seen[scenario.id] = true
    end
    if document[scenario.id] and document[scenario.id] ~= scenario.priority then
      table.insert(errors, "priority mismatch: " .. scenario.id)
    end
    if type(scenario.owner) ~= "string" or not scenario.owner:match("^F%d%d$") then
      table.insert(errors, "invalid owner: " .. tostring(scenario.id))
    end
    if scenario.priority == "P0" or scenario.priority == "P1" then
      if type(scenario.test) ~= "string" or scenario.test == "" then
        table.insert(errors, "missing automated test: " .. scenario.id)
      elseif not scenario.test:find("MiniTest.run_file", 1, true) and scenario.id ~= "AC-SEC-01" then
        table.insert(errors, "unfocused automated test: " .. scenario.id)
      end
    elseif scenario.priority == "P2" and not scenario.test and not scenario.protocol then
      table.insert(errors, "P2 needs a test or protocol: " .. scenario.id)
    end
    local test_path = type(scenario.test) == "string"
      and (scenario.test:match("run_file%('([^']+%.lua)'%)") or scenario.test:match("luafile%s+(tests/[%w_./-]+%.lua)"))
    if not test_path or not exists(root .. "/" .. test_path) then
      table.insert(errors, "missing test file: " .. tostring(scenario.id))
    elseif not read(root .. "/" .. test_path):find(scenario.id, 1, true) then
      table.insert(errors, "test file does not declare " .. scenario.id .. ": " .. test_path)
    end
    if scenario.protocol and not exists(root .. "/" .. scenario.protocol) then
      table.insert(errors, "missing protocol file: " .. scenario.id)
    end
    local has_profiles = {}
    for _, profile in ipairs(scenario.profiles or {}) do
      has_profiles[profile] = true
    end
    for _, profile in ipairs({ "1.17.3", "1.18.9" }) do
      if not has_profiles[profile] then
        table.insert(errors, "missing profile " .. profile .. ": " .. scenario.id)
      end
    end
  end
  for id, present in pairs(seen) do
    if not present then
      table.insert(errors, "missing manifest ID: " .. id)
    end
  end
  return { ok = #errors == 0, errors = errors, manifest_count = #(manifest.scenarios or {}) }
end

return M
