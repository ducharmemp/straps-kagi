local check = require("tests.helpers").check
local straps = require("straps").setup({ max_spawn_depth = 3 })
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
local dispatched, prompts, buffers = {}, 0, {}
local original_confirm = vim.fn.confirm
package.loaded["straps_kagi.transport"] = { call = function(name) dispatched[#dispatched + 1] = name; return "KAGI_RESULT" end }
require("straps_kagi").setup()

local function script(calls, child_calls, grandchild_calls)
  _G.kagi_permission_calls = { calls, child_calls, grandchild_calls }
  _G.kagi_permission_turns, _G.kagi_permission_children = {}, {}
  registry.define({ name = "fn.provider", kind = "fn", source = [==[
return function(req, ctx)
  local turn = (_G.kagi_permission_turns[ctx.bufnr] or 0) + 1
  _G.kagi_permission_turns[ctx.bufnr] = turn
  local depth = vim.b[ctx.bufnr].straps_spawn_depth or 0
  if depth > 0 then _G.kagi_permission_children[depth] = ctx.bufnr end
  local calls = _G.kagi_permission_calls[depth + 1] or {}
  local call = calls[turn]
  if call then return {stop_reason="tool_use",content={{type="tool_use",id="k"..turn,name=call.name,input=call.input}}} end
  return {stop_reason="end_turn",content={{type="text",text="done"}}}
end
]==] }, { scope = "global" })
end
local function new()
  local buffer = state.new_session()
  buffers[#buffers + 1] = buffer
  state.append_text(buffer, "exercise Kagi permissions")
  return buffer
end
local function text(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end
local function run(buffer)
  loop.start(buffer)
  check(vim.wait(10000, function() return not loop.running(buffer) end, 10), "model loop did not finish")
  return text(buffer)
end
local function child(depth)
  check(vim.wait(10000, function()
    local buffer = _G.kagi_permission_children[depth]
    return buffer and not loop.running(buffer)
  end, 10), "child model loop did not finish")
  local buffer = _G.kagi_permission_children[depth]
  buffers[#buffers + 1] = buffer
  return buffer
end
local calls = { { name = "search", input = { query = "test" } }, { name = "fetch", input = { url = "https://example.com/" } } }
before_each(function()
  dispatched, prompts = {}, 0
  vim.fn.confirm = function() prompts = prompts + 1; return 2 end
end)
after_each(function()
  vim.fn.confirm = original_confirm
  for _, buffer in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
  end
  buffers = {}
end)

it("admits search category for both tools through model-origin calls", function()
  local buffer = new()
  registry.grant(buffer, "cap:search")
  script(calls)
  run(buffer)
  check(table.concat(dispatched, ",") == "kagi_search_fetch,kagi_extract", "search category did not admit both tools")
  check(prompts == 0, "search category prompted")
end)

it("denies ungranted and net-only calls before transport", function()
  for _, grant in ipairs({ false, "cap:net" }) do
    local buffer = new()
    if grant then registry.grant(buffer, grant) end
    script(calls)
    local result = run(buffer)
    check(#dispatched == 0, "ungranted or net-only calls reached transport")
    check(result:find("denied", 1, true) ~= nil, "denial missing")
  end
  check(prompts == 4, "denied tools did not each prompt")
end)

it("preserves exact grants across repeated setup without widening", function()
  local buffer = new()
  registry.grant(buffer, registry.tool_grant_key("search"))
  require("straps_kagi").setup()
  script(calls)
  run(buffer)
  check(table.concat(dispatched, ",") == "kagi_search_fetch", "exact grant admitted wrong tools")
  check(prompts == 1, "exact grant lost or widened")
end)

it("does not authorize scoped shadows using global category or exact grants", function()
  local buffer = new()
  registry.grant(buffer, "cap:search")
  registry.grant(buffer, registry.tool_grant_key("search"))
  local previous = registry.set_active_scope(buffer)
  registry.define({ name = "tool.search", kind = "tool",
    source = "return function() _G.kagi_shadow_ran = true; return 'shadow' end" })
  registry.set_active_scope(previous)
  _G.kagi_shadow_ran = false
  script({ calls[1] })
  run(buffer)
  check(not _G.kagi_shadow_ran, "global grants admitted scoped shadow")
  check(prompts == 1, "scoped shadow did not prompt")
end)

it("invalidates exact grants when a scoped definition replaces the tool", function()
  local buffer = new()
  registry.grant(buffer, registry.tool_grant_key("fetch"))
  local previous = registry.set_active_scope(buffer)
  registry.define({ name = "tool.fetch", kind = "tool",
    source = "return function() _G.kagi_fetch_shadow_ran = true; return 'shadow' end" })
  registry.set_active_scope(previous)
  _G.kagi_fetch_shadow_ran = false
  script({ calls[2] })
  run(buffer)
  check(not _G.kagi_fetch_shadow_ran and #dispatched == 0, "global exact grant admitted scoped fetch")
  check(prompts == 1, "fetch shadow did not prompt")
end)

it("denies readonly children without transport or prompts", function()
  local buffer = new()
  registry.grant(buffer, "cap:spawn")
  registry.grant(buffer, "cap:search")
  script({ { name = "spawn", input = { task = "readonly Kagi", readonly = true } } }, calls)
  run(buffer)
  local result = text(child(1))
  check(#dispatched == 0, "readonly child reached transport")
  check(prompts == 0, "readonly child prompted")
  check(result:find("readonly subagent: search is not allowed", 1, true) ~= nil, "readonly denial missing")
end)

it("delegates search category through actual spawned model loops", function()
  local buffer = new()
  registry.grant(buffer, "cap:spawn")
  script({ { name = "spawn", input = { task = "delegated Kagi", allow = { "search" } } } }, calls)
  run(buffer)
  child(1)
  check(table.concat(dispatched, ",") == "kagi_search_fetch,kagi_extract", "delegated category did not admit both tools")
  check(prompts == 0, "delegated category prompted")
end)

it("enforces gated delegation ceilings through model-origin spawn", function()
  local buffer = new()
  registry.grant(buffer, "cap:spawn")
  script({ { name = "spawn", input = { task = "ceiling Kagi", allow = { "spawn", "fetch" } } } }, {
    { name = "spawn", input = { task = "cannot widen", allow = { "search" } } },
    { name = "spawn", input = { task = "exact descendant", allow = { "fetch" } } },
  }, calls)
  run(buffer)
  local result = text(child(1))
  child(2)
  check(result:find("exceeds this session's own grants", 1, true) ~= nil, "gated exact grant widened into category")
  check(table.concat(dispatched, ",") == "kagi_extract", "exact descendant exceeded ceiling")
  check(prompts == 0, "gated descendant prompted")
end)
