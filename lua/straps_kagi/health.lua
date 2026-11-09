local M = {}

function M.check()
  vim.health.start("straps-kagi")
  local found, registry = pcall(require, "straps.registry")
  if not found then
    vim.health.error("Straps is missing from runtimepath")
  elseif not registry.get("fn.capability") then
    vim.health.error("Run Straps setup before straps-kagi setup")
  elseif require("straps_kagi").status().registered then
    vim.health.ok("Kagi search and fetch tools registered")
  else
    vim.health.warn("Kagi tools are not registered; run setup() from trusted configuration")
  end
  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl is available")
  else
    vim.health.error("curl is required for the hosted Kagi transport")
  end
  if not vim.system then vim.health.error("Neovim with vim.system is required") end
  vim.health.info("Hosted endpoint: https://mcp.kagi.com/mcp; health does not resolve credentials or make network requests")
end

return M
