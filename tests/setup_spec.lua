local check = require("tests.helpers").check
local registry = require("straps.registry")
local plugin = require("straps_kagi")

it("requires configured Straps without mutating registration", function()
  local ok, err = pcall(plugin.setup)
  check(not ok and tostring(err):find("Straps setup must run", 1, true) ~= nil, "missing Straps setup accepted")
  check(registry.get("tool.search") == nil and registry.get("fn.capability") == nil, "failed setup mutated registry")
  require("straps").setup({})
end)

it("validates every option before mutation", function()
  local before = registry.get("fn.capability")
  for _, value in ipairs({ false, { unknown = true }, { api_key = "secret" }, { timeout_ms = 0 },
    { timeout_ms = 1.2 }, { max_response_bytes = -1 }, { max_output_bytes = math.huge }, { max_output_bytes = 1 }, { max_output_bytes = 31 } }) do
    check(not pcall(plugin.setup, value), "invalid setup options accepted")
    check(vim.deep_equal(before, registry.get("fn.capability")), "invalid config changed classifier")
  end
end)

it("preflights both generic names before registration", function()
  for _, name in ipairs({ "search", "fetch" }) do
    registry.define({ name = "tool." .. name, kind = "tool", source = "return function() end" })
    local before = registry.get("fn.capability")
    local ok, err = pcall(plugin.setup)
    check(not ok and tostring(err):find("registry collision", 1, true) ~= nil, "collision accepted")
    check(vim.deep_equal(before, registry.get("fn.capability")), "collision changed classifier")
    check(registry.get("tool." .. (name == "search" and "fetch" or "search")) == nil, "collision partially installed tools")
    registry.remove("tool." .. name)
  end
end)

it("rejects setup in an active scope", function()
  local buffer = vim.api.nvim_create_buf(false, true)
  registry.ensure_scope(buffer)
  local previous = registry.set_active_scope(buffer)
  local ok, err = pcall(plugin.setup)
  registry.set_active_scope(previous)
  vim.api.nvim_buf_delete(buffer, { force = true })
  check(not ok and tostring(err):find("trusted configuration", 1, true) ~= nil, "scoped setup accepted")
end)

it("preserves classifiers and category extensions in both setup orders", function()
  _G.kagi_categories = { "edit", "custom" }
  registry.define({ name = "fn.capability", kind = "fn", source = [==[
local base = require("straps.registry").bind("fn.capability")
return function(name, input)
  if name == nil then return _G.kagi_categories end
  if name == "custom_tool" then return input.category end
  return base(name, input)
end
]==] })
  local function extension()
    registry.define({ name = "fn.capability", kind = "fn", source = [==[
local base = require("straps.registry").bind("fn.capability")
return function(name, input)
  if name ~= nil then return base(name, input) end
  local categories = vim.list_extend({}, base())
  if not vim.tbl_contains(categories, "browser") then categories[#categories + 1] = "browser" end
  return categories
end
]==] })
  end
  extension()
  plugin.setup()
  check(vim.deep_equal(registry.call("fn.capability"), { "edit", "custom", "browser", "search" }), "earlier extension lost")
  check(vim.deep_equal(_G.kagi_categories, { "edit", "custom" }), "base category array mutated")
  local list = registry.call("fn.capability")
  list[1] = "changed"
  check(registry.call("fn.capability")[1] == "edit", "mutable category array retained")
  check(registry.call("fn.capability", "custom_tool", { category = "custom" }) == "custom", "custom classifier lost")
  check(registry.call("fn.capability", "fetch", {}) == "search", "fetch metadata not classified")
  _G.kagi_categories = { "search", "custom" }
  registry.define({ name = "fn.capability", kind = "fn", source = [==[
local base = require("straps.registry").bind("fn.capability")
return function(name, input)
  if name == nil then return _G.kagi_categories end
  return base(name, input)
end
]==] })
  plugin.setup()
  extension()
  plugin.setup()
  check(vim.deep_equal(registry.call("fn.capability"), { "search", "custom", "browser" }), "later extension lost")
end)

it("preserves definition versions and resolves credentials only on invocation", function()
  local calls = 0
  plugin.setup({ api_key = function() calls = calls + 1; return "secret" end })
  local search, fetch, classifier = registry.get("tool.search"), registry.get("tool.fetch"), registry.get("fn.capability")
  plugin.setup()
  check(vim.deep_equal(search, registry.get("tool.search")), "search version changed")
  check(vim.deep_equal(fetch, registry.get("tool.fetch")), "fetch version changed")
  check(vim.deep_equal(classifier, registry.get("fn.capability")), "classifier version changed")
  check(calls == 0, "setup resolved credentials")
  local config = plugin.config()
  check(config.timeout_ms == 30000 and config.max_response_bytes == 1048576 and config.max_output_bytes == 100000,
    "config defaults changed")
  config.timeout_ms = 1
  check(plugin.config().timeout_ms == 30000, "config returned mutable internal state")
end)

it("reports status and health without credentials or network", function()
  local calls = 0
  plugin.setup({ api_key = function() calls = calls + 1; error("credential resolved") end })
  local old_health, old_system = vim.health, vim.system
  local reports = {}
  vim.health = setmetatable({}, { __index = function(_, key) return function(message) reports[#reports + 1] = key .. ":" .. message end end })
  vim.system = function() error("health spawned a process") end
  local ok, err = pcall(require("straps_kagi.health").check)
  vim.health, vim.system = old_health, old_system
  check(ok, tostring(err))
  check(plugin.status().registered == true and calls == 0, "health or status resolved credentials")
  check(table.concat(reports):find("ok:Kagi search and fetch tools registered", 1, true) ~= nil, "health registration missing")
end)

it("reports missing dependencies and absent setup without network", function()
  local old_health, old_system, old_executable = vim.health, vim.system, vim.fn.executable
  local old_registry = package.loaded["straps.registry"]
  local reports = {}
  vim.health = setmetatable({}, { __index = function(_, key) return function(message) reports[#reports + 1] = key .. ":" .. message end end })
  vim.system = nil
  vim.fn.executable = function() return 0 end
  package.loaded["straps.registry"] = { get = function() return nil end }
  local ok, err = pcall(require("straps_kagi.health").check)
  package.loaded["straps.registry"] = old_registry
  vim.health, vim.system, vim.fn.executable = old_health, old_system, old_executable
  check(ok, tostring(err))
  local report = table.concat(reports)
  check(report:find("error:Run Straps setup", 1, true) ~= nil, "health omitted missing setup")
  check(report:find("error:curl is required", 1, true) ~= nil, "health omitted missing curl")
  check(report:find("error:Neovim with vim.system", 1, true) ~= nil, "health omitted missing vim.system")
end)

it("retains global registration while status observes scoped shadows", function()
  local buffer = vim.api.nvim_create_buf(false, true)
  registry.ensure_scope(buffer)
  local previous = registry.set_active_scope(buffer)
  registry.define({ name = "tool.search", kind = "tool", source = "return function() end" })
  check(plugin.status().registered == false, "status ignored scoped shadow")
  registry.set_active_scope(previous)
  vim.api.nvim_buf_delete(buffer, { force = true })
  check(plugin.status().registered == true, "scoped shadow changed global registration")
end)

it("rejects replacement definitions on repeated setup", function()
  registry.define(registry.get("tool.fetch"), { scope = "global" })
  local before = registry.get("fn.capability")
  local ok, err = pcall(plugin.setup)
  check(not ok and tostring(err):find("registry collision", 1, true) ~= nil, "replacement accepted")
  check(vim.deep_equal(before, registry.get("fn.capability")), "replacement changed classifier")
end)
