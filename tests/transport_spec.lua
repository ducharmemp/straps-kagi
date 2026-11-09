local H = require("tests.helpers")
local check = H.check
require("straps").setup({})
local registry = require("straps.registry")
local transport = require("straps_kagi.transport")
local root, old_path, original_system
local key = 'secret-"\\token'

local function write(path, text) vim.fn.writefile(vim.split(text, "\n", { plain = true }), root .. "/" .. path) end
local function read(path) return table.concat(vim.fn.readfile(root .. "/" .. path), "\n") end
local function response(n, message, extra)
  write("response." .. n, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" .. (extra or "") .. "\r\n" .. vim.json.encode(message))
end
local function prepare(session)
  response(1, { jsonrpc = "2.0", id = 1, result = { protocolVersion = "2025-06-18" } },
    session and "Mcp-Session-Id: session-test\r\n" or nil)
  write("response.2", "HTTP/1.1 202 Accepted\r\n\r\n")
  response(3, { jsonrpc = "2.0", id = 2, result = { content = { { type = "text", text = "Title\nhttps://example.com\n# Markdown" } } } })
  write("response.4", "HTTP/1.1 204 No Content\r\n\r\n")
end
local function run(options, cancel_at, context)
  options = vim.tbl_extend("force", { api_key = function() return key end, timeout_ms = 1500 }, options or {})
  local handlers, cancelled, done, ok, result = {}, false, false, nil, nil
  local ctx = { bufnr = 0, cancelled = function() return cancelled end }
  ctx.on_cancel = function(fn) handlers[#handlers + 1] = fn end
  ctx.await = function(start)
    local co = coroutine.running()
    local resolved = false
    start(function(value)
      if resolved then return end
      resolved = true
      vim.schedule(function() assert(coroutine.resume(co, value)) end)
    end)
    local value = coroutine.yield()
    handlers = {}
    return value
  end
  if context then context(ctx) end
  if cancel_at then
    local function cancel_when_ready()
      if done then return end
      if type(cancel_at) == "function" and not cancel_at() then vim.defer_fn(cancel_when_ready, 5); return end
      cancelled = true
      for _, fn in ipairs(handlers) do fn() end
    end
    vim.defer_fn(cancel_when_ready, type(cancel_at) == "number" and cancel_at or 5)
  end
  local co = coroutine.create(function()
    ok, result = pcall(transport.call, "kagi_search_fetch", { query = "hello" }, options, ctx)
    done = true
  end)
  assert(coroutine.resume(co))
  assert(vim.wait(4000, function() return done end, 5), "transport test did not finish")
  return ok, result
end
local function failed(fragment, options, cancel_at)
  local ok, text = run(options, cancel_at)
  check(not ok and text:find(fragment, 1, true) ~= nil, "error contains " .. fragment .. ": " .. tostring(text))
  return text
end
local function idle()
  check(registry.subprocess_state().in_flight == 0, "all subprocess slots released")
  check(#registry.subprocess_state().waiters == 0, "all queued subprocess waiters removed")
end

describe("Kagi transport", function()
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local fixture = vim.fn.getcwd() .. "/tests/transport_curl.sh"
    local source = table.concat(vim.fn.readfile(fixture), "\n"):gsub("#!/usr/bin/env bash", "#!" .. vim.fn.exepath("bash"), 1)
    write("curl", source)
    vim.fn.setfperm(root .. "/curl", "rwx------")
    old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path
    vim.env.STRAPS_KAGI_TRANSPORT_FIXTURE = root
    original_system = vim.system
    prepare()
  end)
  after_each(function()
    vim.system = original_system
    vim.env.PATH = old_path
    vim.env.STRAPS_KAGI_TRANSPORT_FIXTURE = nil
    vim.fn.delete(root, "rf")
  end)

  it("preserves text and supplies auth and request only through stdin", function()
    local ok, text = run()
    check(ok and text == "Title\nhttps://example.com\n# Markdown", "tool text preserved")
    check(read("argv.1"):find(key, 1, true) == nil, "credential absent from argv")
    check(read("argv.1"):find("--config\n-", 1, true) ~= nil, "curl reads stdin configuration")
    check(read("stdin.1"):find('Authorization: Bearer secret-\\"\\\\token', 1, true) ~= nil, "credential config escaped")
    check(read("stdin.3"):find("tools/call", 1, true) ~= nil, "tool call sent")
    check(read("count") == "3", "one initialization and one tool call")
    idle()
  end)

  it("carries a session and deletes it on success", function()
    prepare(true)
    local ok = run()
    check(ok, "session call succeeds")
    check(read("stdin.3"):find("Mcp-Session-Id: session-test", 1, true) ~= nil, "session propagated")
    check(read("stdin.4"):find('request = "DELETE"', 1, true) ~= nil, "session deleted")
    idle()
  end)

  it("reports cleanup failures without retrying the tool", function()
    prepare(true)
    write("response.4", "HTTP/1.1 500 Failure\r\n\r\nfailed")
    local ok, text = run()
    check(ok and text:find("session cleanup failed: HTTP 500", 1, true) ~= nil, "cleanup failure reported")
    check(read("count") == "4", "tool not retried for cleanup failure")
    idle()
  end)

  it("accepts SSE notifications, correlated responses and rejects server requests", function()
    write("response.3", 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n'
      .. ': ping\n\ndata: {"jsonrpc":"2.0","method":"notifications/message"}\n\n'
      .. 'data: {"jsonrpc":"2.0","id":99,"method":"sampling/createMessage"}\n\n'
      .. 'event: message\ndata: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"SSE"}]}}\n\n')
    local ok, text = run()
    check(ok and text == "SSE", "SSE tool content returned")
    check(read("stdin.4"):find("-32601", 1, true) ~= nil, "unsupported request receives protocol error")
    check(read("stdin.4"):find('\\"id\\":99', 1, true) ~= nil, "protocol error correlates server request")
    idle()
  end)

  it("finishes SSE after the correlated response without awaiting EOF", function()
    write("response.3", 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n'
      .. 'data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"stream done"}]}}\n\n')
    write("waitafter.3", "")
    local ok, text = run({ timeout_ms = 500 })
    check(ok and text == "stream done", "correlated SSE response completes an open stream")
    idle()
  end)

  it("finishes an open SSE stream after informational HTTP headers", function()
    write("response.3", 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n'
      .. 'data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"continued stream"}]}}\n\n')
    write("waitafter.3", "")
    local ok, text = run({ timeout_ms = 150 })
    check(ok and text == "continued stream", "informational headers allow open SSE completion")
    idle()
  end)

  for _, kind in ipairs({ "HTTP", "tool", "JSON-RPC", "cleanup", "failed cleanup" }) do
    it("bounds sanitized " .. kind .. " failures including their prefix", function()
      local message = key .. string.rep("é", 80)
      if kind == "HTTP" then write("response.3", "HTTP/1.1 500 Failure\r\n\r\n" .. message)
      elseif kind == "tool" then
        response(3, { jsonrpc = "2.0", id = 2, result = { isError = true, content = { { type = "text", text = message } } } })
      elseif kind == "JSON-RPC" then
        response(3, { jsonrpc = "2.0", id = 2, error = { code = -32000, message = message } })
      else
        prepare(true)
        response(3, { jsonrpc = "2.0", id = 2, result = { content = { { type = "text", text = "" } } } })
        write("response.4", "HTTP/1.1 500 Failure\r\n\r\n" .. message)
        if kind == "failed cleanup" then
          response(3, { jsonrpc = "2.0", id = 2, error = { code = -32000, message = message } })
        end
      end
      local ok, text = run({ max_output_bytes = 74 })
      check(ok == (kind == "cleanup"), kind .. " preserves success or failure")
      check(#text <= 74, kind .. " failure obeys output cap")
      check(text:sub(-19) == "\n[output truncated]", kind .. " failure retains full marker")
      check(text:find(key, 1, true) == nil, kind .. " failure redacts credential")
      check(text:find("[REDACTED]", 1, true) ~= nil, kind .. " failure sanitizes before truncation")
      check(pcall(vim.str_utfindex, text, "utf-32", #text, true), kind .. " failure remains UTF-8")
      if not ok then check(text:sub(1, 6) == "kagi: ", kind .. " failure includes prefix within cap") end
      idle()
    end)
  end

  it("rejects output caps too small for a complete marker", function()
    failed("invalid max_output_bytes", { max_output_bytes = 1 })
    check(vim.fn.filereadable(root .. "/count") == 0, "invalid output cap prevents spawn")
    idle()
  end)

  for _, content in ipairs({ { type = "text", text = "not a list" }, vim.empty_dict() }) do
    it("rejects object-shaped tool content " .. vim.json.encode(content), function()
      response(3, { jsonrpc = "2.0", id = 2, result = { content = content } })
      failed("invalid tool content")
      idle()
    end)
  end

  for _, stage in ipairs({ "encoding", "guard", "await", "start" }) do
    it("releases admission when " .. stage .. " raises before spawning", function()
      local original_encode, original_try = vim.json.encode, registry.try_call
      local release, held_checks = nil, 0
      registry.try_call = function(name, ...)
        local value = original_try(name, ...)
        if name == "fn.subprocess_acquire" then release = value end
        return value
      end
      if stage == "encoding" then vim.json.encode = function() error("encoding failure", 0) end end
      local ok, text = run(nil, nil, function(ctx)
        if stage == "guard" then
          ctx.cancelled = function()
            if registry.subprocess_state().in_flight > 0 then held_checks = held_checks + 1 end
            return held_checks >= 2
          end
        elseif stage == "await" then ctx.await = function() error("await failure", 0) end
        elseif stage == "start" then ctx.on_cancel = function() error("start failure", 0) end end
      end)
      vim.json.encode, registry.try_call = original_encode, original_try
      local held = registry.subprocess_state().in_flight
      if release then release() end
      check(not ok and text:find(stage == "guard" and "cancelled" or stage .. " failure", 1, true) ~= nil,
        stage .. " failure reported")
      check(held == 0, stage .. " failure releases acquired slot")
      check(vim.fn.filereadable(root .. "/count") == 0, stage .. " failure prevents spawn")
      idle()
    end)
  end

  it("rejects malformed JSON", function()
    write("response.3", "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{")
    failed("malformed JSON response")
    idle()
  end)

  it("rejects response ID mismatches", function()
    response(3, { jsonrpc = "2.0", id = 44, result = {} })
    failed("ID mismatch")
    idle()
  end)

  it("rejects unsupported protocols before tool invocation", function()
    response(1, { jsonrpc = "2.0", id = 1, result = { protocolVersion = "1999-01-01" } })
    failed("unsupported MCP protocol")
    check(read("count") == "1", "no tool call after failed negotiation")
    idle()
  end)

  it("preserves explicit tool errors and redacts echoed credentials", function()
    response(3, { jsonrpc = "2.0", id = 2, result = { isError = true, content = { { type = "text", text = "denied " .. key } } } })
    local text = failed("tool error: denied [REDACTED]")
    check(text:find(key, 1, true) == nil, "credential removed from tool error")
    idle()
  end)

  it("redacts HTTP errors", function()
    write("response.3", "HTTP/1.1 401 Denied\r\n\r\n" .. key)
    failed("HTTP 401: [REDACTED]")
    idle()
  end)

  it("reports JSON-RPC error codes and messages", function()
    response(3, { jsonrpc = "2.0", id = 2, error = { code = -32000, message = "server " .. key } })
    failed("JSON-RPC error -32000: server [REDACTED]")
    idle()
  end)

  it("rejects non-text content", function()
    response(3, { jsonrpc = "2.0", id = 2, result = { content = { { type = "image", data = "x" } } } })
    failed("unsupported non-text")
    idle()
  end)

  it("bounds wire bytes during streaming", function()
    write("response.3", string.rep("x", 50000))
    failed("wire byte limit", { max_response_bytes = 1024 })
    idle()
  end)

  it("bounds UTF-8 output and marks truncation", function()
    response(3, { jsonrpc = "2.0", id = 2, result = { content = { { type = "text", text = string.rep("é", 80) } } } })
    local ok, text = run({ max_output_bytes = 42 })
    check(ok and #text <= 42 and text:find("[output truncated]", 1, true) ~= nil, "output byte cap and marker")
    check(pcall(vim.str_utfindex, text, "utf-32", #text, true), "truncated output remains UTF-8")
    idle()
  end)

  for _, stage in ipairs({ 1, 2, 3, 4 }) do
    it("cancels transport at lifecycle stage " .. stage, function()
      prepare(true)
      write("wait." .. stage, "")
      failed("cancelled", nil, function()
        return vim.fn.filereadable(root .. "/count") == 1 and tonumber(read("count")) == stage
      end)
      check(tonumber(read("count")) == stage, "cancellation starts no further request at stage " .. stage)
      idle()
    end)
  end

  it("enforces a total process deadline", function()
    write("wait.1", "")
    failed("total deadline exceeded", { timeout_ms = 60 })
    idle()
  end)

  it("removes a timed-out admission waiter and never spawns it", function()
    registry.define({ name = "fn.subprocess_limit", kind = "fn", source = "return function() return 1 end" })
    local release = registry.call("fn.subprocess_acquire", {})
    failed("total deadline exceeded", { timeout_ms = 60 })
    check(vim.fn.filereadable(root .. "/count") == 0, "queued deadline prevents spawn")
    release()
    idle()
  end)

  it("removes a cancelled admission waiter", function()
    local release = registry.call("fn.subprocess_acquire", {})
    failed("cancelled", nil, 40)
    check(vim.fn.filereadable(root .. "/count") == 0, "queued cancellation prevents spawn")
    release()
    idle()
  end)

  it("deletes sessions after a tool error", function()
    prepare(true)
    response(3, { jsonrpc = "2.0", id = 2, error = { code = -32001, message = "failure" } })
    failed("JSON-RPC error -32001")
    check(read("stdin.4"):find('request = "DELETE"', 1, true) ~= nil, "failed tool session deleted")
    idle()
  end)

  it("uses stored defaults and validates explicit callback overrides without fallback", function()
    local credentials = require("straps_kagi.credentials")
    credentials.store("fixture-stored-key")
    local ok = run({ api_key = credentials.resolve })
    check(ok, "default resolver failed with stored fixture")
    check(read("stdin.1"):find("fixture-stored-key", 1, true) ~= nil, "stored key did not reach transport")
    credentials.store(false)
    for _, value in ipairs({ "has space", "nonascii-é", false, string.rep("x", 4097) }) do
      local before = read("count")
      local accepted = run({ api_key = function() return value end })
      check(not accepted, "invalid callback credential accepted")
      check(read("count") == before, "invalid callback spawned transport")
    end
    local accepted, failure = run({ api_key = function() error("fixture-private-callback") end })
    check(not accepted and not failure:find("fixture-private-callback", 1, true), "callback error leaked secret")
  end)

  it("rejects missing credentials before spawning", function()
    failed("KAGI_API_KEY is missing", { api_key = function() return nil end })
    check(vim.fn.filereadable(root .. "/count") == 0, "missing credential prevents spawn")
    idle()
  end)

  it("releases admission on spawn failure without leaking error details", function()
    vim.system = function() error("spawn " .. key) end
    local text = failed("could not spawn curl")
    check(text:find(key, 1, true) == nil, "spawn details cannot expose credentials")
    idle()
  end)
end)
