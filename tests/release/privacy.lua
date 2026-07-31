local log = require("opencode.log")
local acceptance_id = "AC-SEC-01"
assert(acceptance_id)
local path = vim.fn.stdpath("state") .. "/opencode.nvim.log"
local before = vim.uv.fs_stat(path)
local offset = before and before.size or 0
local canaries = {
  "PROMPT_CANARY_7c90",
  "BASE_CANARY_a128",
  "REPLACEMENT_CANARY_5ee1",
  "AUTH_CANARY_421d",
  vim.uv.os_homedir() .. "/PRIVATE_CANARY",
}

local Runtime = require("opencode.runtime")
local runtime = Runtime.new(canaries[5])
runtime:transition("starting")
runtime:transition("ready")
runtime.client = { cancel_requests = function() end }
runtime.sidebar = { dead = function() end }
runtime:on_server_exit(runtime.server_generation)
assert(runtime.state == "disconnected")

for _, state in ipairs({ "completed", "conflict", "scope_violation", "error", "disconnected" }) do
  assert(log.write({
    level = state == "error" and "error" or "info",
    root_hash = canaries[5],
    runtime_state = state,
    endpoint = "https://opencode:" .. canaries[4] .. "@127.0.0.1:1234/session/private",
    error_class = state == "error" and canaries[1] or nil,
  }))
end

for _, field in ipairs({ "prompt", "base", "replacement", "authorization", "password", "source", "diff" }) do
  assert(not log.write({ [field] = canaries[1] }), "content-shaped field was accepted: " .. field)
end

local handle = assert(vim.uv.fs_open(path, "r", 384))
local stat = assert(vim.uv.fs_fstat(handle))
local appended = assert(vim.uv.fs_read(handle, stat.size - offset, offset))
vim.uv.fs_close(handle)
for _, canary in ipairs(canaries) do
  assert(not appended:find(canary, 1, true), "privacy canary leaked")
end
print("Privacy runtime canary passed")
