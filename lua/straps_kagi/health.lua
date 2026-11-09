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
  local dir = require("straps_kagi.credentials").config_dir()
  if dir then
    local path = dir .. "/kagi_api_key"
    local stat, _, code = vim.uv.fs_stat(path)
    local link = vim.uv.fs_lstat(path)
    if stat and stat.type == "file" and stat.mode % 64 == 0 then
      vim.health.ok("Stored Kagi key permissions restrict access to the owner: " .. path)
    elseif stat then
      vim.health.error("Stored Kagi key must be a regular file with mode 0600: " .. path)
    elseif link or code ~= "ENOENT" then
      vim.health.error("Stored Kagi key path cannot be inspected: " .. path)
    else
      vim.health.info("Optional stored key path: " .. path .. "; use :StrapsKagiLogin or KAGI_API_KEY")
    end
  else vim.health.warn("No absolute XDG_CONFIG_HOME or HOME for stored Kagi credentials") end
  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl is available")
  else
    vim.health.error("curl is required for the hosted Kagi transport")
  end
  if not vim.system then vim.health.error("Neovim with vim.system is required") end
  vim.health.info("Hosted endpoint: https://mcp.kagi.com/mcp; health does not resolve credentials or make network requests")
end

return M
