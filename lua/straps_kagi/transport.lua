local M = {}
local endpoint = "https://mcp.kagi.com/mcp"
local protocol = "2025-06-18"

local function quote(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

local function cut(text, limit)
  if #text <= limit then return text end
  return text:sub(1, limit + vim.str_utf_start(text, limit + 1))
end

local function http_parts(raw)
  local headers, body = raw:match("^(.-)\n\n(.*)$")
  local status = headers and tonumber(headers:match("^HTTP/%S+ (%d+)"))
  while status and status >= 100 and status < 200 do
    headers, body = body:match("^(.-)\n\n(.*)$")
    status = headers and tonumber(headers:match("^HTTP/%S+ (%d+)"))
  end
  return headers, body, status
end

function M.call(name, arguments, config, ctx)
  config = config or {}
  ctx = ctx or {}
  local limit = config.max_output_bytes or 100000
  if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 32 or limit == math.huge then
    error("kagi: invalid max_output_bytes (minimum 32)", 0)
  end
  local function bounded(text)
    local marker = "\n[output truncated]"
    if #text > limit then return cut(text, limit - #marker) .. marker end
    return text
  end
  local key
  local function sanitize(value)
    local text = tostring(value)
    if key and key ~= "" then text = text:gsub(key:gsub("(%W)", "%%%1"), "[REDACTED]") end
    return text
  end
  local deadline = vim.uv.hrtime() / 1e6 + (config.timeout_ms or 30000)
  local cancelled = false
  local function remaining() return math.max(0, math.ceil(deadline - vim.uv.hrtime() / 1e6)) end
  local function is_cancelled() return cancelled or (ctx.cancelled and ctx.cancelled()) end
  local function guard()
    if is_cancelled() then error("cancelled; remote work may continue", 0) end
    if remaining() == 0 then error("total deadline exceeded", 0) end
  end
  local function bounded_await(start, stop)
    guard()
    return ctx.await(function(resolve)
      local finished = false
      local function finish(value)
        if finished then return end
        finished = true
        resolve(value)
      end
      local function abort(reason)
        if finished then return end
        finish({ transport_error = reason })
        if stop then stop() end
      end
      ctx.on_cancel(function()
        cancelled = true
        abort("cancelled; remote work may continue")
      end)
      vim.defer_fn(function() abort("total deadline exceeded") end, remaining())
      if not finished then start(finish) end
    end)
  end
  local session
  local request
  request = function(method, payload)
    guard()
    local admission_handlers = {}
    local admission_ctx = {
      bufnr = ctx.bufnr,
      cancelled = function() return is_cancelled() or remaining() == 0 end,
      on_cancel = function(fn) admission_handlers[#admission_handlers + 1] = fn end,
      await = function(start)
        local result = bounded_await(start, function()
          for _, fn in ipairs(admission_handlers) do pcall(fn) end
        end)
        if type(result) == "table" and result.transport_error then error(result.transport_error, 0) end
        return result
      end,
    }
    local release = require("straps.registry").try_call("fn.subprocess_acquire", admission_ctx,
      { tool = "kagi", bufnr = ctx.bufnr, cmd = endpoint }) or function() end
    local released = false
    local function free()
      if released then return end
      released = true
      release()
    end
    local proc, stopped, chunks, wire = nil, false, {}, 0
    local function stop()
      stopped = true
      if proc then pcall(proc.kill, proc, 9) end
      free()
    end
    local started, result = pcall(function()
      guard()
      local lines = {
        "url = " .. quote(endpoint), "request = " .. quote(method),
        "header = " .. quote("Authorization: Bearer " .. key),
        'header = "Content-Type: application/json"',
        'header = "Accept: application/json, text/event-stream"',
      }
      if session then lines[#lines + 1] = "header = " .. quote("Mcp-Session-Id: " .. session) end
      if not payload or payload.method ~= "initialize" then
        lines[#lines + 1] = "header = " .. quote("MCP-Protocol-Version: " .. protocol)
      end
      if payload then lines[#lines + 1] = "data = " .. quote(vim.json.encode(payload)) end
      local function completed_sse()
        if not payload or payload.id == nil then return false end
        local raw = table.concat(chunks):gsub("\r\n", "\n")
        local headers, body = http_parts(raw)
        if not headers or not headers:lower():find("content%-type:%s*text/event%-stream") then return false end
        local data = {}
        for line in body:gmatch("([^\n]*)\n") do
          if line == "" then
            if #data > 0 then
              local ok, message = pcall(vim.json.decode, table.concat(data, "\n"))
              if ok and type(message) == "table" then
                if message.id == payload.id and not message.method then return true end
                if message.id ~= nil and message.method then return true end
              end
              data = {}
            end
          elseif line:match("^data:") then data[#data + 1] = line:sub(6):gsub("^ ", "") end
        end
        return false
      end
      return bounded_await(function(resolve)
        local function take(err, chunk)
          if err then stop(); resolve({ transport_error = "curl stream failure" }); return end
          if stopped or not chunk then return end
          wire = wire + #chunk
          if wire > (config.max_response_bytes or 1048576) then
            stop(); resolve({ transport_error = "response exceeds wire byte limit" }); return
          end
          chunks[#chunks + 1] = chunk
          if completed_sse() then
            stop()
            resolve({ code = 0 })
          end
        end
        local ok, value = pcall(vim.system,
          { "curl", "--disable", "--silent", "--show-error", "--include", "--suppress-connect-headers", "--no-buffer", "--proto", "=https",
            "--max-redirs", "0", "--max-time", tostring(remaining() / 1000), "--config", "-" },
          { stdin = table.concat(lines, "\n") .. "\n", stdout = take, stderr = function() end },
          function(out) free(); resolve(out) end)
        if not ok then free(); resolve({ transport_error = "could not spawn curl" }); return end
        proc = value
        if stopped then pcall(proc.kill, proc, 9) end
      end, stop)
    end)
    free()
    if not started then stop(); error(result, 0) end
    if not result then stop(); error("transport await interrupted", 0) end
    if result.transport_error then error(result.transport_error, 0) end
    guard()
    if result.code ~= 0 then error("curl failed (exit " .. tostring(result.code) .. ")", 0) end
    local raw = table.concat(chunks):gsub("\r\n", "\n")
    local headers, body, status = http_parts(raw)
    if not headers then error("malformed HTTP response", 0) end
    if not status then error("malformed HTTP status", 0) end
    if status < 200 or status >= 300 then error("HTTP " .. status .. ": " .. body, 0) end
    local headers_lower = headers:lower()
    local assigned = headers:match("\n[Mm][Cc][Pp]%-[Ss][Ee][Ss][Ss][Ii][Oo][Nn]%-[Ii][Dd]:%s*([^\n]+)")
    if assigned then
      if assigned:find("[^%g ]") then error("invalid MCP session header", 0) end
      session = assigned
    end
    if not body:find("%S") then return {} end
    local messages = {}
    local function decode(text)
      local ok, message = pcall(vim.json.decode, text)
      if not ok or type(message) ~= "table" then error("malformed JSON response", 0) end
      messages[#messages + 1] = message
    end
    if headers_lower:find("content%-type:%s*text/event%-stream") then
      local data = {}
      for line in (body .. "\n\n"):gmatch("([^\n]*)\n") do
        if line == "" then
          if #data > 0 then decode(table.concat(data, "\n")); data = {} end
        elseif line:match("^data:") then data[#data + 1] = line:sub(6):gsub("^ ", "") end
      end
    elseif headers_lower:find("content%-type:%s*application/json") then decode(body)
    else error("unsupported response content type", 0) end
    return messages
  end
  local function rpc(payload)
    local messages = request("POST", payload)
    local response
    for _, message in ipairs(messages) do
      if message.jsonrpc ~= "2.0" then error("invalid JSON-RPC version", 0) end
      if message.method then
        if message.id ~= nil then
          request("POST", { jsonrpc = "2.0", id = message.id, error = { code = -32601, message = "Method not found" } })
        end
      elseif payload.id ~= nil then
        if message.id ~= payload.id then error("JSON-RPC response ID mismatch", 0) end
        if response then error("duplicate JSON-RPC response", 0) end
        response = message
      else error("unexpected JSON-RPC response", 0) end
    end
    if payload.id == nil then return end
    if not response then error("missing correlated JSON-RPC response", 0) end
    if response.error then
      error("JSON-RPC error " .. tostring(response.error.code) .. ": " .. tostring(response.error.message), 0)
    end
    if type(response.result) ~= "table" then error("invalid JSON-RPC result", 0) end
    return response.result
  end
  local ok, output = pcall(function()
    if not ctx or not ctx.await or not ctx.on_cancel then error("requires an asynchronous run context", 0) end
    local key_ok, value = pcall(config.api_key or function() return require("straps_kagi.credentials").resolve() end)
    if not key_ok then error("credential resolver failed; check the stored Kagi key permissions and configuration", 0) end
    local cleaned = require("straps_kagi.credentials").clean_key(value)
    if not cleaned then error("KAGI_API_KEY is missing or invalid", 0) end
    key = cleaned
    local initialized = rpc({ jsonrpc = "2.0", id = 1, method = "initialize", params = {
      protocolVersion = protocol, capabilities = vim.empty_dict(), clientInfo = { name = "straps-kagi", version = "0.1.0" },
    } })
    if initialized.protocolVersion ~= protocol then error("unsupported MCP protocol version", 0) end
    rpc({ jsonrpc = "2.0", method = "notifications/initialized" })
    local result = rpc({ jsonrpc = "2.0", id = 2, method = "tools/call", params = { name = name, arguments = arguments } })
    if type(result.content) ~= "table" or not vim.islist(result.content) then error("invalid tool content", 0) end
    local texts = {}
    for _, item in ipairs(result.content) do
      if type(item) ~= "table" or item.type ~= "text" or type(item.text) ~= "string" then
        error("unsupported non-text tool content", 0)
      end
      texts[#texts + 1] = item.text
    end
    local text = table.concat(texts, "\n")
    if result.isError then error("tool error: " .. text, 0) end
    return text
  end)
  if session and not is_cancelled() then
    local cleaned, failure = pcall(request, "DELETE")
    if not cleaned then
      local note = "session cleanup failed: " .. sanitize(failure)
      if ok then output = output .. "\n[" .. note .. "]" else output = tostring(output) .. "; " .. note end
    end
  end
  if is_cancelled() then error(bounded("kagi: cancelled; remote work may continue"), 0) end
  if not ok then error(bounded("kagi: " .. sanitize(output)), 0) end
  return bounded(sanitize(output))
end

return M
