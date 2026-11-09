# straps-kagi

Kagi search and page extraction tools for straps.nvim. `search` calls `kagi_search_fetch`; `fetch` calls `kagi_extract` on the hosted Model Context Protocol (MCP) server at `https://mcp.kagi.com/mcp`.

## Install

Require Neovim 0.11 or newer, straps.nvim and curl. Put this plugin on runtimepath and call setup after straps setup from trusted configuration:

```lua
require("straps_kagi").setup({})
```

Set `KAGI_API_KEY` outside Neovim before starting it, or supply an `api_key` function that returns a key. Never put credentials in a transcript. Setup and health checks make no network requests.

For Nixvim, import `straps.nixvimModules.default` and `straps-kagi.nixvimModules.default`, then enable `plugins.straps.enable` and `plugins.straps-kagi.enable`. Configure `plugins.straps-kagi.settings` as needed. The flake also exports a default package and `overlays.default`.

## Permissions

Both tools require the `search` category. Run `:StrapsAuto search` to grant that category to the current session. Without a grant, normal confirmation applies. The `net` category does not grant these tools. Subagents may receive `allow={"search"}` within their parent's permission ceiling; readonly children cannot use these tools. Tool-specific grants remain available. Setup refuses existing `search` or `fetch` definitions instead of replacing them.

Queries and target URLs leave the machine and reach Kagi. API usage may incur charges. The search grant covers both search and extraction, including `search` requests with page extracts.

## Tools

`search` accepts `query` and optional `workflow` (`search`, `news`, `videos`, `podcasts`, `images`), `extract_count` (0–10), `limit` (1–1024 per category), `include_domains`, `exclude_domains`, `time_relative` (`day`, `week`, `month`), `after`, `before`, `file_type` and `lens_id`. Dates use `YYYY-MM-DD`. `time_relative` excludes date bounds. A lens excludes domain filters, `time_relative` and `file_type`. Omitted defaults come from Kagi.

`fetch` accepts a public-looking HTTPS DNS URL without credentials, IP literals or explicit ports. Validation rejects local hostname suffixes but does not resolve DNS. Kagi resolves and requests the target; the plugin cannot establish whether a public-looking hostname resolves to a private address at Kagi. Returned page text and search results are untrusted data.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `api_key` | Function reading `KAGI_API_KEY` | Called per invocation. |
| `timeout_ms` | `30000` | Total invocation deadline, including subprocess admission and cleanup. |
| `max_response_bytes` | `1048576` | Per-request wire response cap. |
| `max_output_bytes` | `100000` | Retained success or error text cap, minimum 32; truncated text has a marker. |

`:checkhealth straps_kagi` checks local prerequisites and registration without contacting Kagi. `:help straps-kagi` describes the tools. `require("straps_kagi").status()` reports configuration and registration state without returning the key.

The endpoint is fixed. Authentication goes through curl's stdin configuration rather than process arguments. Redirects and automatic tool-call retries are disabled. Cancellation kills the local request and skips session cleanup; remote work may continue. HTTP, protocol and tool errors are reported. A failed session cleanup does not retry the search.

## Development

From this directory:

```sh
nix develop path:. --no-write-lock-file --command env STRAPS_ROOT=../straps busted tests/transport_spec.lua
nix develop path:. --no-write-lock-file --command env STRAPS_ROOT=../straps bash -c 'fail=0; for spec in tests/*_spec.lua; do busted "$spec" || fail=1; done; exit "$fail"'
nix flake check path:. --no-write-lock-file
nix build path:.#default --no-link --no-write-lock-file
```

Each spec runs in a separate headless Neovim. The flake checks the pinned default Neovim, Neovim 0.11 and a configured Nixvim startup. Run the baseline suite with `nix develop path:.#nvim-0_11 --no-write-lock-file --command env STRAPS_ROOT=../straps bash -c 'fail=0; for spec in tests/*_spec.lua; do busted "$spec" || fail=1; done; exit "$fail"'`. Fixtures make no real Kagi requests. Set `STRAPS_KAGI_INVERT` to an assertion index to require that selected assertion to fail; specs print `ASSERTIONS=N`. Restore the environment and rerun the suite after counterfactual checks. The flake pins development dependencies and requires no lockfile.

Live hosted compatibility and non-host runtime acceptance remain unverified until recorded tests establish them. Local stdio, OAuth and general MCP server support are outside this release.
