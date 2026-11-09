# Design

The plugin registers two generic tools backed by Kagi's hosted MCP server. Straps owns tool admission; the transport owns bounded asynchronous HTTP operations.

## Registration

Trusted explicit setup validates options and checks both tool names before registration. Tools declare the `search` capability. A captured `fn.capability` delegate adds `search` to category enumeration while preserving existing classifications and extensions. Repeated setup preserves tool versions. Setup does not run inside an agent scope and does not contact the network.

## Transport

Each invocation resolves credentials from the canonical `straps/kagi_api_key` config path before the environment. An explicit callback overrides default resolution. Existing invalid credential files fail closed. Secret-input login uses an atomic mode-0600 file replacement in a verified mode-0700 directory. Reads validate the opened descriptor and allow secure symlink targets; mutation refuses symlinks. Reads and writes share a 4096-byte key limit. Concurrent hostile replacement of directories by the same user lies outside the credential store's trust boundary.

Each invocation initializes an MCP connection, sends the initialized notification and calls one upstream tool. Protocol version 2025-06-18, JSON responses and Server-Sent Events responses are supported. A server-assigned session identifier propagates to subsequent requests; normal completion attempts session deletion within the deadline. Cancellation stops local transport and skips deletion. Remote work may continue.

Curl receives configuration through stdin. Credentials never appear in process arguments. The fixed HTTPS endpoint does not follow redirects. Shared subprocess admission, per-await cancellation, deadlines and byte caps constrain requests. Tool calls are never retried after an uncertain outcome.

Results preserve text content and report truncation. Unsupported content blocks and protocol errors fail with an explicit error. Unsupported server requests receive a method-not-found response; continued bidirectional streams are outside the supported subset. Returned text is untrusted data.

## Validation and verification

Static tool schemas limit the imported API to search and extraction. Local validation rejects unknown fields, invalid dates, bounds and incompatible filters before transport. Extraction URL checks reject IP literals and local-looking hostnames without local target requests or DNS resolution. The plugin cannot determine upstream DNS results.

Specs use isolated headless Neovim processes and fake curl fixtures. Permission specs drive the model loop to exercise admission. Selected assertion inversions test assertion sensitivity. Authenticated hosted compatibility requires a separate live smoke test; fixture tests do not establish that compatibility.
