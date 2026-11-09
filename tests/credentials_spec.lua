local check = require("tests.helpers").check
local credentials = require("straps_kagi.credentials")
local oauth = require("straps.oauth")
local uv = vim.uv
local root, path, env, originals

local function fixture(value, mode, name)
  local target = name or path
  vim.fn.mkdir(vim.fs.dirname(target), "p")
  if uv.fs_lstat(target) then assert(uv.fs_chmod(target, 384)) end
  local fd = assert(uv.fs_open(target, "w", 384))
  assert(uv.fs_write(fd, value, 0))
  assert(uv.fs_close(fd))
  assert(uv.fs_chmod(target, mode or 384))
  return target
end

local function read(target)
  local fd = assert(uv.fs_open(target, "r", 0))
  local value = assert(uv.fs_read(fd, assert(uv.fs_fstat(fd)).size, 0))
  assert(uv.fs_close(fd))
  return value
end

local function replace(name, fn)
  originals[name] = uv[name]
  uv[name] = fn
end

local function fails(fn, message)
  local ok, err = pcall(fn)
  check(not ok, message)
  check(not tostring(err):find("fixture-secret", 1, true), "error exposed credential")
end

before_each(function()
  root = vim.fn.tempname()
  env = { config = vim.env.XDG_CONFIG_HOME, home = vim.env.HOME, key = vim.env.KAGI_API_KEY }
  vim.env.XDG_CONFIG_HOME, vim.env.HOME, vim.env.KAGI_API_KEY = root .. "/config", root .. "/home", "env-fixture-secret"
  path = root .. "/config/straps/kagi_api_key"
  originals = {}
end)

after_each(function()
  for name, fn in pairs(originals) do uv[name] = fn end
  vim.env.XDG_CONFIG_HOME, vim.env.HOME, vim.env.KAGI_API_KEY = env.config, env.home, env.key
  vim.fn.delete(root, "rf")
end)

it("reads the canonical stored key before the environment and reports its path", function()
  fixture("  stored-fixture-secret\n")
  local key, stored_path = credentials.store()
  check(key == "stored-fixture-secret" and stored_path == path, "canonical store read failed")
  local resolved, source = credentials.resolve()
  check(resolved == key and source == "stored", "environment overrode stored credential")
  check(credentials.clean_key(" key\n") == "key", "clean_key did not use provider validation")
end)

it("uses the environment only for an absent store", function()
  local key, stored_path = credentials.store()
  check(key == nil and stored_path == path, "absent store result changed")
  local resolved, source = credentials.resolve()
  check(resolved == "env-fixture-secret" and source == "env", "environment fallback failed")
  check(credentials.clean_key("a\0b") == nil, "NUL credential accepted")
  for _, value in ipairs({ "", "a b", "a\nb", "a\194\160b" }) do
    vim.env.KAGI_API_KEY = value
    fails(credentials.resolve, "invalid environment credential accepted")
  end
  vim.env.KAGI_API_KEY = nil
  fails(credentials.resolve, "missing credential accepted")
end)

it("fails closed for empty invalid insecure unreadable and nonregular stores", function()
  for _, value in ipairs({ "", " \n", "fixture-secret extra", "fixture-secret\nextra", "fixture-secret\0", "fixture-secret\194\160" }) do
    fixture(value)
    fails(credentials.resolve, "invalid stored credential fell back to environment")
  end
  for _, mode in ipairs({ 420, 416, 0, 128 }) do
    fixture("fixture-secret", mode)
    fails(credentials.resolve, "insecure or unreadable store accepted")
  end
  assert(uv.fs_unlink(path))
  assert(uv.fs_mkdir(path, 448))
  fails(credentials.resolve, "directory store fell back to environment")
end)

it("reads secure symlinks but refuses insecure and dangling targets and all link mutations", function()
  local target = fixture("linked-fixture-secret", 384, root .. "/target")
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert(uv.fs_symlink(target, path))
  check(credentials.store() == "linked-fixture-secret", "secure symlink read failed")
  fails(function() credentials.store("replacement") end, "write replaced symlink")
  fails(function() credentials.store(false) end, "delete removed symlink")
  check(uv.fs_lstat(path).type == "link" and read(target) == "linked-fixture-secret", "link mutation changed target")
  assert(uv.fs_chmod(target, 420))
  fails(credentials.resolve, "insecure symlink target accepted")
  assert(uv.fs_unlink(target))
  fails(credentials.resolve, "dangling symlink fell back to environment")
  fails(function() credentials.store(false) end, "dangling link deletion accepted")
end)

it("checks the opened descriptor rather than trusting path metadata", function()
  fixture("fixture-secret")
  local open = uv.fs_open
  replace("fs_open", function(target, flags, mode)
    if target == path and flags == "r" then uv.fs_chmod(target, 420) end
    return open(target, flags, mode)
  end)
  fails(credentials.resolve, "changed descriptor permissions escaped validation")
end)

it("rejects replaced files and descriptor metadata changes during reads", function()
  fixture("fixture-secret")
  local alternate = fixture("other-fixture-secret", 384, root .. "/alternate")
  local open = uv.fs_open
  replace("fs_open", function(target, flags, mode)
    if target == path and flags == "r" then return open(alternate, flags, mode) end
    return open(target, flags, mode)
  end)
  fails(credentials.resolve, "opened file identity mismatch accepted")
  uv.fs_open, originals.fs_open = open, nil
  local read_fd = uv.fs_read
  replace("fs_read", function(fd, size, offset)
    local value = read_fd(fd, size, offset)
    uv.fs_chmod(path, 420)
    return value
  end)
  fails(credentials.resolve, "descriptor permissions changed during read accepted")
end)

it("fails closed when open read fstat or close fails without exposing errors", function()
  fixture("fixture-secret")
  for _, name in ipairs({ "fs_open", "fs_read", "fs_fstat", "fs_close" }) do
    local original = uv[name]
    replace(name, function(...) 
      if name == "fs_close" then original(...) end
      return nil, "fixture-secret injected failure", "EACCES"
    end)
    fails(credentials.resolve, name .. " failure fell back to environment")
    uv[name], originals[name] = original, nil
  end
end)

it("writes atomically with private file and directory modes and deletes regular files", function()
  local stored_key, stored_path = credentials.store("  written-fixture-secret\n")
  check(stored_key == "written-fixture-secret" and stored_path == path, "write return contract changed")
  check(read(path) == "written-fixture-secret\n", "write did not persist cleaned key")
  check(uv.fs_stat(path).mode % 512 == 384, "credential mode is not 0600")
  check(uv.fs_stat(vim.fs.dirname(path)).mode % 512 == 448, "directory mode is not 0700")
  local removed, deleted_path = credentials.store(false)
  check(removed == true and deleted_path == path and not uv.fs_lstat(path), "delete failed")
  check(credentials.store(false) == false, "absent delete was not false")
  for _, value in ipairs({ true, 42, {}, "", "bad key" }) do
    fails(function() credentials.store(value) end, "invalid write value accepted")
  end
end)

it("resolves absolute configuration roots without relying on core config semantics", function()
  for _, xdg in ipairs({ false, "", "relative", root .. "/config" }) do
    for _, home in ipairs({ false, "", "relative", root .. "/home" }) do
      vim.env.XDG_CONFIG_HOME = xdg or nil
      vim.env.HOME = home or nil
      local expected
      if xdg == root .. "/config" then
        expected = root .. "/config/straps"
      elseif home == root .. "/home" then
        expected = root .. "/home/.config/straps"
      end
      check(credentials.config_dir() == expected, "absolute configuration root selection changed")
    end
  end
end)

it("uses HOME fallback and handles unavailable absolute config roots", function()
  vim.env.XDG_CONFIG_HOME = "relative"
  local expected = root .. "/home/.config/straps/kagi_api_key"
  local _, stored_path = credentials.store("home-fixture-secret")
  check(stored_path == expected, "HOME config fallback changed")
  check(read(expected) == "home-fixture-secret\n", "HOME fallback did not persist key")
  vim.env.HOME = "relative"
  local key, stored_path = credentials.store()
  check(key == nil and stored_path == nil, "no-config read result changed")
  check(credentials.resolve() == "env-fixture-secret", "no-config environment fallback failed")
  local removed, deleted_path = credentials.store(false)
  check(removed == nil and deleted_path == nil, "no-config delete result changed")
  fails(function() credentials.store("fixture-secret") end, "no-config write accepted")
end)

it("refuses nonregular mutations and linked store directories", function()
  vim.fn.mkdir(path, "p")
  fails(function() credentials.store("fixture-secret") end, "directory overwritten")
  fails(function() credentials.store(false) end, "directory deletion attempted")
  vim.fn.delete(vim.fs.dirname(path), "rf")
  vim.fn.mkdir(root .. "/elsewhere", "p")
  assert(uv.fs_symlink(root .. "/elsewhere", vim.fs.dirname(path)))
  fails(function() credentials.store("fixture-secret") end, "linked directory mutation accepted")
  check(uv.fs_stat(root .. "/elsewhere").mode % 512 ~= 448, "linked directory was chmodded")
end)

it("preserves the existing key and cleans temps after partial write close or rename failures", function()
  fixture("old-fixture-secret\n")
  for _, name in ipairs({ "fs_write", "fs_close", "fs_rename" }) do
    local original = uv[name]
    replace(name, function(...)
      if name == "fs_write" then return 1 end
      if name == "fs_close" then original(...) end
      return nil, "fixture-secret injected failure", "EIO"
    end)
    fails(function() credentials.store("new-fixture-secret") end, name .. " failure accepted")
    uv[name], originals[name] = original, nil
    check(read(path) == "old-fixture-secret\n", name .. " failure changed old key")
    check(#vim.fn.glob(path .. ".tmp.*", false, true) == 0, name .. " failure leaked temp")
  end
end)

it("refuses FIFO stores before opening them", function()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert(vim.system({ "mkfifo", path }):wait().code == 0)
  local opened = false
  replace("fs_open", function() opened = true; return nil, "unexpected open", "EIO" end)
  fails(credentials.resolve, "FIFO store accepted")
  check(not opened, "FIFO store was opened")
end)

it("bounds key sizes on reads and writes while preserving the existing key", function()
  local limit = string.rep("x", 4096)
  credentials.store(limit)
  check(credentials.store() == limit, "maximum key failed round trip")
  fails(function() credentials.store(limit .. "x") end, "oversized write accepted")
  check(read(path) == limit .. "\n", "oversized write changed existing key")
  fixture(limit .. "x\n")
  fails(credentials.resolve, "oversized read accepted")
  vim.env.KAGI_API_KEY = limit .. "x"
  assert(uv.fs_unlink(path))
  fails(credentials.resolve, "oversized environment key accepted")
end)

it("refuses destination changes and cleans temps after failed final inspection", function()
  fixture("old-fixture-secret\n")
  local close = uv.fs_close
  local stat = uv.fs_lstat
  replace("fs_close", function(fd)
    local result = close(fd)
    uv.fs_lstat = function(target)
      if target == path then return nil, "fixture-secret", "EACCES" end
      return stat(target)
    end
    return result
  end)
  originals.fs_lstat = stat
  fails(function() credentials.store("new-fixture-secret") end, "failed final inspection accepted")
  uv.fs_close, originals.fs_close = close, nil
  uv.fs_lstat, originals.fs_lstat = stat, nil
  check(read(path) == "old-fixture-secret\n", "final inspection failure changed existing key")
  check(#vim.fn.glob(path .. ".tmp.*", false, true) == 0, "final inspection failure leaked temp")
  local target = fixture("external-fixture-secret", 384, root .. "/external")
  replace("fs_close", function(fd)
    local result = close(fd)
    uv.fs_unlink(path)
    uv.fs_symlink(target, path)
    return result
  end)
  fails(function() credentials.store("new-fixture-secret") end, "symlink replacement during write accepted")
  uv.fs_close, originals.fs_close = close, nil
  check(uv.fs_lstat(path).type == "link" and read(target) == "external-fixture-secret", "write replaced new symlink")
  check(#vim.fn.glob(path .. ".tmp.*", false, true) == 0, "destination replacement leaked temp")
end)

it("refuses temporary-file creation and delete failures without changing the key", function()
  fixture("old-fixture-secret\n")
  local open = uv.fs_open
  replace("fs_open", function(target, flags, mode)
    if flags == "wx" then return nil, "fixture-secret", "EACCES" end
    return open(target, flags, mode)
  end)
  fails(function() credentials.store("new-fixture-secret") end, "temporary creation failure accepted")
  check(read(path) == "old-fixture-secret\n", "temporary creation failure changed key")
  replace("fs_unlink", function() return nil, "fixture-secret", "EACCES" end)
  fails(function() credentials.store(false) end, "delete failure accepted")
  check(read(path) == "old-fixture-secret\n", "delete failure changed key")
end)

it("verifies directory creation and chmod results before writing", function()
  local ensure = oauth.ensure_dir
  oauth.ensure_dir = function() end
  local ok = pcall(credentials.store, "fixture-secret")
  oauth.ensure_dir = ensure
  check(not ok and not uv.fs_lstat(path), "failed directory creation accepted")
  fixture("old-fixture-secret")
  assert(uv.fs_chmod(vim.fs.dirname(path), 493))
  replace("fs_chmod", function() return nil, "fixture-secret", "EACCES" end)
  fails(function() credentials.store("new-fixture-secret") end, "failed chmod accepted")
  check(read(path) == "old-fixture-secret", "directory failure changed old key")
  check(#vim.fn.glob(path .. ".tmp.*", false, true) == 0, "directory failure leaked temp")
end)
