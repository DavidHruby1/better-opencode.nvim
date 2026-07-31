local root = arg[1] or "."
local report = dofile(root .. "/tests/release/validator.lua").validate(root)
if not report.ok then
  for _, err in ipairs(report.errors) do
    io.stderr:write(err .. "\n")
  end
  os.exit(1)
end
print(string.format("Acceptance manifest valid: %d scenarios", report.manifest_count))
