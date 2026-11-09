local check = require("tests.helpers").check
require("straps").setup({})
local calls = {}
package.loaded["straps_kagi.transport"] = { call = function(name, arguments, config, ctx)
  calls[#calls + 1] = { name = name, arguments = vim.deepcopy(arguments), config = config, ctx = ctx }
  return "Title\nhttps://example.com\n# Markdown"
end }
require("straps_kagi").setup()
local tools = require("straps_kagi.tools")

it("exposes only static upstream fields and the search category", function()
  local registry = require("straps.registry")
  for _, spec in ipairs(tools.specs) do
    local entry = registry.get("tool." .. spec.name)
    check(entry.capability == "search", "tool category changed")
    check(entry.input_schema == spec.schema or vim.deep_equal(entry.input_schema, spec.schema), "registered schema differs")
    check(spec.schema.additionalProperties == false, "schema allows unknown fields")
  end
  local properties = tools.specs[1].schema.properties
  for _, key in ipairs(vim.fn.sort(vim.tbl_keys(properties))) do
    local property = properties[key]
    if property.enum then
      for _, value in ipairs(property.enum) do
        check(pcall(tools.call, "search", { query = "test", [key] = value }, {}), "documented enum rejected for " .. key)
      end
      check(not pcall(tools.call, "search", { query = "test", [key] = "UNKNOWN_VALUE" }, {}), "unknown enum accepted for " .. key)
    end
  end
  local fields = vim.tbl_keys(properties)
  table.sort(fields)
  check(table.concat(fields, ",") == "after,before,exclude_domains,extract_count,file_type,include_domains,lens_id,limit,query,time_relative,workflow",
    "search schema fields differ from inspected upstream")
end)

it("maps generic names and preserves text and invocation context", function()
  local ctx = { bufnr = 41 }
  local result = tools.call("search", { query = "test" }, ctx)
  check(result == "Title\nhttps://example.com\n# Markdown", "tool changed returned text")
  check(calls[#calls].name == "kagi_search_fetch" and calls[#calls].arguments.query == "test", "search routing changed")
  check(calls[#calls].ctx == ctx and type(calls[#calls].config.api_key) == "function", "invocation context/config lost")
  tools.call("fetch", { url = "https://example.com/path?a=b" }, ctx)
  check(calls[#calls].name == "kagi_extract" and calls[#calls].arguments.url == "https://example.com/path?a=b", "fetch routing changed")
end)

it("rejects malformed object types and unknown fields before transport", function()
  for _, value in ipairs({ false, "test", { "test" }, { query = "test", api_key = "secret" }, { query = 2 }, {} }) do
    local count = #calls
    check(not pcall(tools.call, "search", value, {}), "invalid search input accepted")
    check(#calls == count, "invalid input reached transport")
  end
  for _, item in ipairs({ { "search", "query" }, { "fetch", "url" } }) do
    local count = #calls
    check(not pcall(tools.call, item[1], { [item[2]] = vim.NIL }, {}), "JSON null accepted")
    check(#calls == count, "JSON null reached transport")
  end
  check(not pcall(tools.call, "unknown", {}, {}), "unknown tool accepted")
end)

it("validates every schema integer bound and type", function()
  local properties = tools.specs[1].schema.properties
  for _, key in ipairs(vim.fn.sort(vim.tbl_keys(properties))) do
    local property = properties[key]
    if property.type == "integer" then
      for _, value in ipairs({ property.minimum - 1, property.maximum + 1, property.minimum + 0.5, "1", math.huge }) do
        check(not pcall(tools.call, "search", { query = "test", [key] = value }, {}), "invalid integer accepted for " .. key)
      end
      check(pcall(tools.call, "search", { query = "test", [key] = property.minimum }, {}), "integer minimum rejected for " .. key)
      check(pcall(tools.call, "search", { query = "test", [key] = property.maximum }, {}), "integer maximum rejected for " .. key)
    end
  end
end)

it("validates calendar dates including leap years", function()
  for _, value in ipairs({ "2023-02-29", "1900-02-29", "2024-04-31", "2024-00-01", "2024-13-01", "0000-01-01", "2024-1-01", "2024-01-00" }) do
    for _, field in ipairs({ "after", "before" }) do
      check(not pcall(tools.call, "search", { query = "test", [field] = value }, {}), "invalid calendar date accepted")
    end
  end
  check(pcall(tools.call, "search", { query = "test", after = "2000-02-29", before = "2024-02-29" }, {}), "valid leap dates rejected")
end)

it("validates domain arrays, nonempty strings and incompatible filters", function()
  for _, input in ipairs({
    { query = "" }, { query = "test", file_type = "" }, { query = "test", lens_id = "" },
    { query = "test", include_domains = "example.com" }, { query = "test", exclude_domains = { 2 } },
    { query = "test", include_domains = { "" } }, { query = "test", exclude_domains = { domain = "example.com" } },
    { query = "test", time_relative = "day", after = "2024-01-01" },
    { query = "test", time_relative = "week", before = "2024-01-01" },
    { query = "test", lens_id = "15", include_domains = { "example.com" } },
    { query = "test", lens_id = "15", exclude_domains = { "example.com" } },
    { query = "test", lens_id = "15", time_relative = "month" },
    { query = "test", lens_id = "15", file_type = "pdf" },
  }) do
    local count = #calls
    check(not pcall(tools.call, "search", input, {}), "invalid filters accepted")
    check(#calls == count, "invalid filters reached transport")
  end
  check(pcall(tools.call, "search", { query = "test", include_domains = { "example.com" }, exclude_domains = {} }, {}),
    "valid domain filters rejected")
  check(pcall(tools.call, "search", { query = "test", lens_id = "15", after = "2024-01-01" }, {}), "lens and date rejected")
end)

it("rejects local and ambiguous fetch targets without local requests", function()
  local old_system = vim.system
  vim.system = function() error("validation made a local request") end
  local values = { "http://example.com", "https://localhost/", "https://service.local/", "https://service.internal/",
    "https://127.0.0.1/", "https://2130706433/", "https://0x7f000001/", "https://[::1]/", "https://10.0.0.1/",
    "https://user:secret@example.com/", "https://example.com:443/", "https://example.com\\@localhost/", "https://example.com\n/",
    "https://example.com%00/", "file:///etc/passwd", "https://-bad.example/", "https://example..com/" }
  for _, url in ipairs(values) do
    local count = #calls
    check(not pcall(tools.call, "fetch", { url = url }, {}), "unsafe fetch target accepted: " .. url)
    check(#calls == count, "unsafe fetch target reached transport")
  end
  vim.system = old_system
  check(pcall(tools.call, "fetch", { url = "https://www.example.com/path#fragment" }, {}), "public HTTPS target rejected")
end)
