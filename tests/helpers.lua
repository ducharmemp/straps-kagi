local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local straps = vim.env.STRAPS_ROOT
if not straps or straps == "" then straps = root .. "/../straps" end
assert(vim.fn.isdirectory(straps .. "/lua/straps") == 1, "set STRAPS_ROOT to a straps checkout")
vim.opt.rtp:prepend(straps)
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. straps .. "/lua/?.lua;"
  .. straps .. "/lua/?/init.lua;" .. package.path
local isolated = vim.fn.tempname()
vim.env.HOME = isolated .. "/home"
vim.fn.mkdir(vim.env.HOME, "p")
for _, key in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME" }) do
  vim.env[key] = isolated .. "/" .. key
  vim.fn.mkdir(vim.env[key], "p")
end
vim.env.KAGI_API_KEY = nil
local M = { root = root, straps_root = straps }
local assertion = 0
function M.check(value, message)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_KAGI_INVERT) == assertion then
    value, message = not value, "COUNTERFACTUAL=" .. assertion .. ": " .. message
  end
  assert(value, message)
end
require("busted").teardown(function()
  print("\nASSERTIONS=" .. assertion)
  vim.fn.delete(isolated, "rf")
end)
return M
