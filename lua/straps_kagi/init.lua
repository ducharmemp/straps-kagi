local M = {}
local installed = {}
local config

local function options(value)
  assert(value == nil or type(value) == "table", "straps-kagi: setup options must be a table")
  local result = {
    api_key = function() return vim.env.KAGI_API_KEY end,
    timeout_ms = 30000,
    max_response_bytes = 1048576,
    max_output_bytes = 100000,
  }
  for key, item in pairs(value or {}) do
    assert(result[key] ~= nil, "straps-kagi: unknown option " .. tostring(key))
    if key == "api_key" then
      assert(type(item) == "function", "straps-kagi: api_key must be a function")
    else
      assert(type(item) == "number" and item == math.floor(item) and item >= 1 and item <= 2147483647,
        "straps-kagi: " .. key .. " must be a positive integer at most 2147483647")
    end
    result[key] = item
  end
  assert(result.max_output_bytes >= 32, "straps-kagi: max_output_bytes must be at least 32")
  return result
end

function M.setup(value)
  local candidate = options(value)
  local found, registry = pcall(require, "straps.registry")
  assert(found and type(registry.define) == "function" and type(registry.bind) == "function",
    "straps-kagi: Straps registry is required")
  assert(registry.active_scope() == nil, "straps-kagi: setup must run from trusted configuration outside a Straps session")
  assert(registry.get("fn.capability"), "straps-kagi: Straps setup must run before adapter setup")
  local specs = require("straps_kagi.tools").specs
  for _, spec in ipairs(specs) do
    local name = "tool." .. spec.name
    local existing = registry.get(name)
    if existing then
      assert(installed[name] and vim.deep_equal(existing, installed[name]), "straps-kagi: registry collision at " .. name)
    else
      assert(not installed[name], "straps-kagi: registered tool was removed: " .. name)
    end
  end
  if not vim.tbl_contains(registry.call("fn.capability"), "search") then
    registry.define({ name = "fn.capability", kind = "fn", doc = "Preserve tool classifications and add the search category.",
      source = [==[
local base = require("straps.registry").bind("fn.capability")
return function(name, input)
  if name ~= nil then return base(name, input) end
  local categories = vim.list_extend({}, base())
  if not vim.tbl_contains(categories, "search") then categories[#categories + 1] = "search" end
  return categories
end
]==],
    }, { scope = "global" })
  end
  for _, spec in ipairs(specs) do
    local name = "tool." .. spec.name
    if not installed[name] then
      registry.define({ name = name, kind = "tool", capability = "search", doc = spec.doc, input_schema = spec.schema,
        source = ('return function(input, ctx) return require("straps_kagi.tools").call(%q, input, ctx) end'):format(spec.name),
      }, { scope = "global" })
      installed[name] = registry.get(name)
    end
  end
  config = candidate
  return M
end

function M.config()
  assert(config, "straps-kagi: run setup() before calling tools")
  return vim.tbl_extend("force", {}, config)
end

function M.status()
  local registry = require("straps.registry")
  local registered = config ~= nil
  for name, definition in pairs(installed) do
    registered = registered and vim.deep_equal(registry.get(name), definition)
  end
  return { configured = config ~= nil, registered = registered, endpoint = "https://mcp.kagi.com/mcp" }
end

return M
