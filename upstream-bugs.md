# Upstream bugs

This file tracks bugs in PureHTTP2.jl's upstream dependencies and in the
tooling PureHTTP2.jl relies on for development (Julia itself, Documenter,
TestItemRunner, CI actions, etc.). It is the canonical place to
record a finding when the root cause lives outside this repository —
CLAUDE.md's working rule for contributors and AI assistants is
"if you find an upstream bug create entry in upstream-bugs.md file".

Every entry MUST include:

- **Package**: the upstream package, tool, or service.
- **Issue**: a one-line summary of what goes wrong.
- **Upstream link**: URL to the upstream tracker (issue, PR, or commit).
- **Impact on PureHTTP2.jl**: what breaks, where it breaks, and whether a
  workaround exists locally.
- **Workaround**: the local workaround, if any, and where it lives
  in this repository.
- **Status**: one of `open`, `fixed-upstream`, `worked-around`,
  `resolved`.

Entries are added in reverse-chronological order (newest first).

## Entries

### Nghttp2Wrapper.jl `HTTP2Server` drops the response body

- **Package**: Nghttp2Wrapper.jl
- **Issue**: `Nghttp2Wrapper.HTTP2Server` dispatched request
  handlers, collected the returned `ServerResponse` object, and
  sent it via `nghttp2_submit_response2(session, stream_id,
  nva, nvlen, C_NULL)` — the trailing `C_NULL` is the
  `data_provider` argument. With `C_NULL`, nghttp2 submitted
  HEADERS with `END_STREAM` set and **no DATA frames**, so the
  `ServerResponse.body` bytes never reached the client. Any
  handler returning `ServerResponse(200, "hello")` was seen by
  a client as a 200 response with an empty body.
- **Upstream link**: fixed in
  [s-celles/Nghttp2Wrapper.jl@c2e2a06](https://github.com/s-celles/Nghttp2Wrapper.jl/commit/c2e2a06506faab7bf7eb0dec9fd6c7f34ab6941b)
  ("fix(server): stream ServerResponse body via nghttp2_data_provider").
  The fix wires a real `nghttp2_data_provider` into the response
  submission path: a `ResponseBodySource` struct pinned in
  `ServerContext.response_bodies` + a `@cfunction`-compatible
  `_server_data_source_read_cb` that streams body bytes into
  nghttp2's output buffer and signals `NGHTTP2_DATA_FLAG_EOF` on
  the final chunk. A `"server response body round-trip"`
  regression test was added to
  `Nghttp2Wrapper.jl/test/server_tests.jl` to prevent recurrence.
- **Impact on PureHTTP2.jl**: the `Interop: h2c live TCP client`
  test item in `test/interop/testitems_interop.jl` had a
  placeholder `@test isempty(result.body)` with a flip-to-
  equality TODO pending this fix. Once `test/interop/Project.toml`
  was updated to pin Nghttp2Wrapper at the fixed commit
  (`c2e2a06506faab7bf7eb0dec9fd6c7f34ab6941b`), the assertion
  was flipped to
  `@test String(result.body) == "hello from nghttp2"` and the
  full interop suite still passes 24,937 + 1 broken, unchanged.
- **Workaround**: no longer required — the upstream fix is
  live in the commit PureHTTP2.jl's `test/interop/` env pins at.
- **Status**: `fixed-upstream` — resolved in Nghttp2Wrapper.jl
  commit `c2e2a06506faab7bf7eb0dec9fd6c7f34ab6941b`.

### OpenSSL.jl does not bind `SSL_CTX_set_alpn_select_cb`

- **Package**: OpenSSL.jl
- **Issue**: OpenSSL.jl exports the client-side ALPN setter
  (`ssl_set_alpn`, wrapping `SSL_CTX_set_alpn_protos`) but does
  **not** bind the server-side selection callback
  (`SSL_CTX_set_alpn_select_cb`). Without that binding, a Julia
  TLS server cannot choose a protocol from the list advertised by
  a connecting client, which is the whole point of ALPN on the
  server side.
- **Upstream link**:
  <https://github.com/JuliaWeb/OpenSSL.jl/issues> — specific
  issue URL TBD. Milestone 7 release prep attempted to file a
  GitHub issue at `JuliaWeb/OpenSSL.jl` but the filing step
  could not be automated from the release workflow (interactive
  GitHub authentication required on a third-party repository).
  The issue is scheduled to be filed manually by the maintainer
  as a post-release follow-up citing RFC 7301 §3.2 and this
  entry; this field will be updated to the specific issue URL
  in the next patch release.
- **Impact on PureHTTP2.jl**: at Milestone 5 this blocked
  server-side `h2` (HTTP/2 over TLS) entirely — PureHTTP2.jl's
  `serve_connection!` could not negotiate `h2` in a TLS
  handshake because the OpenSSL.jl client-side `ssl_set_alpn`
  call is a no-op on a server context. `h2c` (cleartext) was
  unaffected and remained the primary delivered capability at
  M5–M7. At Milestone 7.5, PureHTTP2.jl ships a second TLS backend
  via `ext/PureHTTP2ReseauExt.jl` that uses
  [Reseau.jl](https://github.com/JuliaServices/Reseau.jl) for
  server-side TLS instead — Reseau binds
  `SSL_CTX_set_alpn_select_cb` directly at
  `src/5_tls.jl:725-732` in Reseau v1.0.1 via `@cfunction`, so
  the `h2` selection the OpenSSL.jl path could not perform is
  fully functional through the Reseau path. PureHTTP2.jl is no
  longer **blocked** by this upstream gap, even though the
  gap itself remains open in OpenSSL.jl.
- **Workaround**: since Milestone 7.5, the
  `PureHTTP2ReseauExt` package extension provides three
  constructor-style helpers —
  `PureHTTP2.reseau_h2_server_config`, `reseau_h2_client_config`,
  `reseau_h2_connect` — that pre-populate `alpn_protocols =
  ["h2"]` on Reseau's `TLS.Config` and hand the resulting
  `TLS.Conn` directly to `PureHTTP2.serve_connection!` /
  `PureHTTP2.open_connection!`. The M5 `PureHTTP2OpenSSLExt` helper
  `PureHTTP2.set_alpn_h2!(::OpenSSL.SSLContext)` stays in place
  for client-side use and for users who do not want to add
  Reseau as a second TLS dependency; server-side callers who
  must use OpenSSL.jl's code path continue to need the
  upstream binding. See `docs/src/tls.md` under "## TLS
  backends" → "Reseau.jl" for the worked server-side example,
  and `specs/009-reseau-tls-backend/contracts/README.md`
  Section 2 for the symmetry-break rationale
  (constructor-style helpers vs mutator on an immutable
  struct). No ccall workaround is attempted in PureHTTP2.jl
  itself — constitution Principle I's TLS carve-out is
  satisfied via Reseau's own, already-pure-Julia `ccall`
  sites into `OpenSSL_jll`.
- **Status**: `worked-around via Reseau.jl` — PureHTTP2.jl no
  longer blocks on this gap as of Milestone 7.5. The upstream
  binding is still a valuable addition for users who want the
  OpenSSL-only code path without Reseau as a second
  dependency, so the entry stays open from the OpenSSL.jl
  perspective. When OpenSSL.jl lands the binding, PureHTTP2.jl
  can add an analogous `PureHTTP2.set_alpn_select_h2!` server-
  side helper to `PureHTTP2OpenSSLExt` and this entry flips to
  `fixed-upstream`.

### gRPC-specific header helpers live in src/stream.jl

- **Package**: PureHTTP2.jl (self-reference — layering concern inherited from M0 extraction)
- **Issue**: `src/stream.jl` defines `get_grpc_encoding`,
  `get_grpc_accept_encoding`, `get_grpc_timeout`, and
  `get_metadata`, each of which reads gRPC-specific headers
  (`grpc-encoding`, `grpc-accept-encoding`, `grpc-timeout`, and
  the set of reserved gRPC headers excluded from user metadata).
  These concepts are gRPC-layer, not HTTP/2-layer, and
  conceptually belong in a gRPC adapter (e.g., gRPCServer.jl)
  rather than in PureHTTP2.jl.
- **Upstream link**: n/a — this is a design concern in PureHTTP2.jl
  itself, inherited from the original extraction from gRPCServer.jl
  at Milestone 0. See the Provenance appendix in `CHANGELOG.md`.
- **Impact on PureHTTP2.jl**: the exported public API surface (post-
  Milestone 3) includes these four symbols. Removing them is a
  breaking change for any downstream consumer that adopted them
  between their introduction and the refactor, so the removal
  has to wait for a major-version bump or for the downstream
  consumers to be identified.
- **Workaround**: documented on the `Streams` page in
  `docs/src/streams.md` under "### gRPC convenience helpers".
  The note explicitly tells users these helpers are gRPC-layer
  conveniences kept for historical reasons.
- **Status**: `open` — revisit when Milestone 8 (gRPCServer.jl
  reverse integration) makes the natural split between PureHTTP2.jl
  and a gRPC layer easy to execute, or when a dedicated
  layering-cleanup milestone is scheduled.
