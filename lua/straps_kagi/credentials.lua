local M = {}
local uv = vim.uv
local function oauth() return require("straps.oauth") end
local limit = 4096

local function fail(message)
  error("straps-kagi: " .. message, 0)
end

function M.clean_key(value)
  if type(value) ~= "string" then return nil, "empty" end
  local key = vim.trim(value)
  if key == "" then return nil, "empty" end
  if key:find("[%s%c]") then return nil, "spaces or control characters" end
  if key:find("[\128-\255]") then return nil, "non-ASCII characters" end
  if #key > limit then return nil, "too long" end
  return key
end

local function absolute(path)
  return path and path ~= "" and vim.startswith(path, "/") and path or nil
end

function M.config_dir()
  local config_home = absolute(vim.env.XDG_CONFIG_HOME)
  if not config_home then
    local home = absolute(vim.env.HOME)
    config_home = home and (home .. "/.config")
  end
  return config_home and (config_home .. "/straps") or nil
end

local function identity(a, b)
  return a and b and a.dev == b.dev and a.ino == b.ino and a.type == b.type
end

local function private_file(st)
  return st and st.type == "file" and st.mode % 64 == 0 and math.floor(st.mode / 256) % 2 == 1
end

local function inspect(path)
  local st, _, code = uv.fs_lstat(path)
  if not st and code ~= "ENOENT" then fail("could not inspect credential path") end
  return st
end

local function unchanged(path, previous)
  local current = inspect(path)
  if previous == nil then return current == nil end
  return identity(current, previous)
end

local function mutation_target(path)
  local st = inspect(path)
  if st and st.type ~= "file" then fail("credential mutation requires a regular file, never a symlink") end
  return st
end

local function read(path, lst)
  local before = uv.fs_stat(path)
  if not private_file(before) then fail("stored credential must be a readable private regular file") end
  local fd = uv.fs_open(path, "r", 0)
  if not fd then fail("could not open stored credential") end
  local ok, result = pcall(function()
    local st = uv.fs_fstat(fd)
    if not private_file(st) or not identity(st, before) then fail("stored credential changed or is insecure") end
    if st.size > limit + 1 then fail("stored credential is too long") end
    local value = uv.fs_read(fd, limit + 2, 0)
    if type(value) ~= "string" or #value ~= st.size then fail("could not read complete stored credential") end
    local after = uv.fs_fstat(fd)
    if not private_file(after) or not identity(st, after) or after.size ~= st.size
      or not identity(after, uv.fs_stat(path)) or not unchanged(path, lst) then
      fail("stored credential changed during read")
    end
    local key = M.clean_key(value)
    if not key then fail("stored credential is invalid or empty") end
    return key
  end)
  local closed = uv.fs_close(fd)
  if not ok then fail("could not read a valid secure stored credential") end
  if not closed then fail("could not close stored credential") end
  return result, path
end

function M.store(value)
  if value ~= nil and value ~= false and type(value) ~= "string" then
    fail("credential value must be a string, false or nil")
  end
  local key
  if type(value) == "string" then
    key = M.clean_key(value)
    if not key then fail("credential is invalid or empty") end
  end
  local dir = M.config_dir()
  if not dir then
    if value == nil or value == false then return nil, nil end
    fail("no absolute configuration directory is available")
  end
  local path = dir .. "/kagi_api_key"
  if value == nil then
    local lst = inspect(path)
    if not lst then return nil, path end
    return read(path, lst)
  end
  local previous = mutation_target(path)
  local directory = inspect(dir)
  if directory and directory.type ~= "directory" then fail("credential directory must be a directory, never a symlink") end
  if value == false then
    if not previous then return false, path end
    if not unchanged(path, previous) or not unchanged(dir, directory) then fail("credential path changed before deletion") end
    if not uv.fs_unlink(path) then fail("could not delete stored credential") end
    return true, path
  end
  local ensured = pcall(oauth().ensure_dir, dir)
  local secured = inspect(dir)
  if not ensured or not secured or secured.type ~= "directory" or secured.mode % 4096 ~= 448
    or (directory and not identity(directory, secured)) then
    fail("could not secure credential directory with mode 0700")
  end
  local tmp = path .. ".tmp." .. oauth().random_b64url(12)
  local fd = uv.fs_open(tmp, "wx", 384)
  if not fd then fail("could not create credential temporary file") end
  local payload = key .. "\n"
  local ok = pcall(function()
    local st = uv.fs_fstat(fd)
    if not private_file(st) or st.mode % 4096 ~= 384 then fail("credential temporary file is insecure") end
    local written = uv.fs_write(fd, payload, 0)
    if written ~= #payload then fail("could not write complete credential") end
  end)
  local closed = uv.fs_close(fd)
  if not ok or not closed then
    uv.fs_unlink(tmp)
    fail("could not write and close credential temporary file")
  end
  local saved = pcall(function()
    if not unchanged(path, previous) or not unchanged(dir, secured) then fail("credential path changed before save") end
    local current_dir = inspect(dir)
    if not current_dir or current_dir.mode % 4096 ~= 448 then fail("credential directory became insecure") end
    if not uv.fs_rename(tmp, path) then fail("could not save credential") end
  end)
  if not saved then
    uv.fs_unlink(tmp)
    fail("could not save credential")
  end
  return key, path
end

function M.resolve()
  local key = M.store()
  if key then return key, "stored" end
  key = M.clean_key(vim.env.KAGI_API_KEY)
  if key then return key, "env" end
  fail("no usable credential; run :StrapsKagiLogin or set KAGI_API_KEY")
end

return M
