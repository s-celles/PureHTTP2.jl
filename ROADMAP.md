# Roadmap

This document outlines the planned milestones for PureHTTP2.jl, a pure Julia
HTTP/2 implementation. The library was extracted from the `http2`
module of
[gRPCServer.jl](https://github.com/s-celles/gRPCServer.jl/tree/develop/src/http2)
and validated against
[Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl) (a thin
wrapper over the `libnghttp2` reference implementation).

Each milestone respects the
[constitution](.specify/memory/constitution.md): pure Julia only, TDD with
`TestItemRunner.jl`, SemVer + Keep a Changelog, warning-free Documenter
builds, and RFC-grounded cross-tests against Nghttp2Wrapper.jl.

## Open questions

### Request bodies larger than one flow-control window

**Status**: Open — receive-side flow control works, the transfer still does not
complete.

Against gRPCClient.jl, a unary request whose body exceeds the 65535-byte initial
window never reaches the handler. A packet capture shows the server emitting
`RST_STREAM(FLOW_CONTROL_ERROR)` against traffic that appears legal, after which
the stream is reset.

Seven hypotheses were measured, all eliminated:

- [x] a duplicated `process_frame` in the consumer — measured with it removed
- [x] frames handled in the consumer's wait loop — that loop is never entered
- [x] double crediting — an instrumentation artefact; the ledger is correct
- [x] the 50% refresh threshold — lowering it to 0.001 changes nothing
- [x] drift between `available` and the granted total — the invariant holds
      (unit test in `testitems_flow_control.jl`)
- [x] the `consume_recv!` guard being the blocker — made non-fatal, no change
- [x] that guard being the *source* of the reset — it never fires; the warning
      logged zero times over a full 200 KB run

**Next step**: find what else raises `FLOW_CONTROL_ERROR`. `consume_recv!` is
exonerated, so the reset originates elsewhere in the connection layer. Start
from a packet capture rather than server-side instrumentation — the latter
produced two false conclusions in this investigation because it only covered
one of several frame paths.

Only `PureHTTP2Backend` in gRPCServer.jl is affected; its default HTTP.jl
backend handles these requests correctly.

### Interop entry point runs main-environment testitems

**Status**: Open — low impact, order-dependent.

`test/interop/runtests.jl` uses `@run_package_tests` with no filter, so it also
runs the main-environment items. One of them,
`Transport: ALPN helper stub (no extension)`, asserts that the Reseau extension
is *not* loaded — true only if no earlier item loaded Reseau in the same
process. It passes on CI and fails locally purely on execution order. The entry
point should filter to `"Interop: "` items, mirroring what `test/runtests.jl`
does in the other direction.

## Status snapshot (2026-04-13)

| Milestone | Version         | Status         | Commit    | Tests (main / interop) |
| --------- | --------------- | -------------- | --------- | ---------------------- |
| M0        | `0.0.1`         | ✅ Completed   | `d617015` | 1,021 / n/a            |
| M1        | `0.0.1`         | ✅ Completed   | `667e4c8` | 1,021 / n/a            |
| M2        | `0.0.1 → 0.1.0` | ✅ Completed   | `e652b15` | 24,709 / n/a           |
| M3        | `0.1.0 → 0.2.0` | ✅ Completed   | `d29d64b` | 24,767 / n/a           |
| M4        | `0.2.0 → 0.3.0` | ✅ Completed   | `a5df743` | 24,767 / 24,872        |
| M5        | `0.3.0 → 0.4.0` | ✅ Completed   | `c874bce` | 24,779 / 24,900        |
| M6        | `0.4.0 → 0.5.0` | ✅ Completed   | `e9070d5` | 24,809 / 24,937 +1 broken |
| M7        | `0.5.0 → 0.1.0` + `v0.1.0` tag | ✅ Completed | `c692f2c` | 24,809 / 24,937 +1 broken |
| M7.5      | `0.1.0 → 0.2.0` + `v0.2.0` tag | ✅ Completed | *TBD on main merge* | 24,809 / 24,947 + 0 broken |
| Rename    | `0.2.0 → 0.3.0` + `v0.3.0` tag | ✅ Completed (`HTTP2` → `PureHTTP2`) | *TBD on main merge* | 24,809 / 24,960 + 0 broken |
| M8        | `0.3.0 → 0.4.0` | ✅ Completed (request-handler API) | `317dd6e` | 24,857 / 25,007 + 1 broken |
| M9        | `0.4.0 → 0.5.0` | ✅ Completed (streaming + SSE example) | `cebd74e` | 24,910 / 25,060 + 1 broken |
| M10       | → `v0.6.0`      | Not started    |           |                        |

**Principle III (Specification Conformance & Reference Parity)** is
operationally fulfilled for **server role** (M4, deepened at M5),
**client role** (M6), and **server-side h2 over TLS** (M7.5 via
Reseau.jl).

## TLS backends

PureHTTP2.jl supports h2 over TLS via **two independent optional
backends**, both delivered as package extensions under `ext/` so
the main `[deps]` stays empty (constitution Principle I). Users
pick one based on which TLS stack they already have loaded and
which direction of the handshake they need:

| Backend | Extension | Role | Added | Rationale |
|---|---|---|---|---|
| **OpenSSL.jl** | `ext/PureHTTP2OpenSSLExt.jl` | Client-side ALPN helper (`set_alpn_h2!`) | M5 | Wraps `OpenSSL.ssl_set_alpn` to emit the RFC 7301 §3.1 wire format for the `h2` identifier. Suitable for TLS **clients** connecting to an h2 server. Server-side ALPN select was blocked on an upstream OpenSSL.jl binding gap — see Deferred upstream below. |
| **Reseau.jl** | `ext/PureHTTP2ReseauExt.jl` | Server-side + client-side h2 TLS (`reseau_h2_server_config`, `reseau_h2_client_config`, `reseau_h2_connect`) | M7.5 | Reseau binds `SSL_CTX_set_alpn_select_cb` internally, which unblocks server-side ALPN negotiation. The three constructor-style helpers pre-populate `alpn_protocols = ["h2"]` on a `Reseau.TLS.Config` and hand back a ready-to-use handle. Suitable for **both** server and client roles. |

Both extensions load automatically via `Base.get_extension` when
the corresponding backend package is in the environment — no
`using` incantations beyond `using PureHTTP2` + `using OpenSSL`
or `using Reseau`. The shared constant
`PureHTTP2.ALPN_H2_PROTOCOLS = ["h2"]` is exported from the main
module as the canonical ALPN protocol list that both extensions
consume.

**Choosing between them**:

- **Client only, already using OpenSSL.jl** → use
  `PureHTTP2.set_alpn_h2!(ssl_ctx)` (M5's OpenSSL extension).
- **Server role (any), or client role where you want a
  single consistent TLS stack** → use the Reseau helpers
  (M7.5's Reseau extension).
- **Both roles, willing to take both packages** → perfectly
  fine; the two extensions do not conflict. Each binds to its
  own type and the method tables stay disjoint.

See `docs/src/tls.md` for worked examples of both backends and
the `docs/src/client.md` "Over TLS (h2) via PureHTTP2ReseauExt"
subsection for the Reseau-side client pattern.

**Deferred upstream** (tracked in `upstream-bugs.md`):

- OpenSSL.jl: `SSL_CTX_set_alpn_select_cb` binding missing —
  **no longer blocking PureHTTP2.jl** as of M7.5 (worked around
  via Reseau.jl). Still a valuable upstream addition for users
  who want an OpenSSL-only server-role code path without adding
  Reseau as a second backend.
- Nghttp2Wrapper.jl: `HTTP2Server` handler drops response bodies
  — **fixed upstream** at M7 via commit `c2e2a06`.

---

## Milestone 0 — Source Extraction from gRPCServer.jl ✅

**Status**: Completed (commit `d617015`, version `0.0.1`)

Lifted the existing pure-Julia HTTP/2 implementation out of
gRPCServer.jl together with its tests, preserving git history and
copyright.

**Source modules** (`~3100` LOC) in `gRPCServer/src/http2/`:

- [x] `frames.jl` (~547 LOC) — frame types, wire format encode/decode
- [x] `hpack.jl` (~963 LOC) — HPACK header compression (RFC 7541)
- [x] `stream.jl` (~462 LOC) — stream state machine (RFC 9113 §5)
- [x] `connection.jl` (~717 LOC) — connection lifecycle, SETTINGS, preface
- [x] `flow_control.jl` (~440 LOC) — window update / flow control (RFC 9113 §5.2)

**Tests carried over** from `gRPCServer/test/unit/`:

- [x] `test_hpack.jl` (~378 LOC)
- [x] `test_http2_stream.jl` (~488 LOC)
- [x] `test_http2_conformance.jl` (~427 LOC)
- [x] `test_stream_state_validation.jl` (~218 LOC)
- [x] `test_connection_management.jl` (~244 LOC)
- [x] Relevant slices of `test_streams.jl` and http2-specific helpers
      from `TestUtils.jl`

**Tasks**:

- [x] Sources copied into `src/` with per-file RFC citations preserved
- [x] Tests copied into `test/` with `GRPCServer.HTTP2` references
      re-homed to `HTTP2` module paths
- [x] Provenance recorded in `CHANGELOG.md` Provenance appendix with
      the originating gRPCServer.jl commit SHA (`4abc0932`)
- [x] `CHANGELOG.md` `Unreleased` seeded with the initial import entry

**Exit criteria met**: sources and tests in-tree, module compiles,
provenance recorded.

---

## Milestone 1 — Package Scaffolding & CI ✅

**Status**: Completed (commit `667e4c8`, version `0.0.1`)

Stood up PureHTTP2.jl as a real Julia package so the extracted code could
be developed in isolation.

- [x] `Project.toml` with `name = "HTTP2"`, UUID
      `7d1e1b98-28e7-4969-8df9-5a308937986a`, `[compat]` entries, and
      minimum Julia version `1.10`
- [x] `src/PureHTTP2.jl` root module `include`ing the five extracted files
      in dependency order
- [x] `test/runtests.jl` wired to `TestItemRunner.jl`
- [x] GitHub Actions workflow: `julia=[1.10, 1] × os=[ubuntu-latest]`
- [x] `Documenter.jl` skeleton under `docs/` with landing page and
      API index — builds warning-free with `checkdocs=:exports`
- [x] `CHANGELOG.md` seeded in Keep a Changelog format with an
      `Unreleased` section
- [x] `upstream-bugs.md` seeded (empty) per project convention

**Exit criteria met**: `Pkg.test()` runs under TestItemRunner, CI green,
warning-free Documenter build.

---

## Milestone 2 — Frames & HPACK, Converted to TestItemRunner ✅

**Status**: Completed (commit `e652b15`, version `0.0.1 → 0.1.0`)

Brought the two leaf modules — frames and HPACK — up to constitution
standard without touching higher layers.

- [x] `test_hpack.jl` refactored into `@testitem` units (8 items)
- [x] `test_http2_conformance.jl` frame slices refactored into
      `@testitem` units grouped by frame type (13 items covering DATA,
      HEADERS, PRIORITY, RST_STREAM, SETTINGS, PING, GOAWAY,
      WINDOW_UPDATE, CONTINUATION)
- [x] Doctests added for `encode_frame` / `decode_frame` / HPACK
      encoder-decoder round-trips
- [x] `docs/src/frames.md` and `docs/src/hpack.md` pages
- [x] HPACK conformance suite against
      [hpack-test-case](https://github.com/http2jp/hpack-test-case) —
      4 `@testitem` groups × 32 stories × 3 suites = **23,688
      conformance assertions**
- [x] First formal public API + doctests

**Exit criteria met**: frames and HPACK pass 24,709 assertions
including the hpack-test-case vectors; public API documented.

---

## Milestone 3 — Stream, Flow Control & Connection ✅

**Status**: Completed (commit `d29d64b`, version `0.1.0 → 0.2.0`)

Brought the stateful layers up to the same standard as M2.

- [x] `test_http2_stream.jl` + `test_stream_state_validation.jl`
      refactored into 21 `Stream:` `@testitem` units organised by
      state transition
- [x] `test_connection_management.jl` refactored into 5 `Connection:`
      `@testitem` units covering preface, SETTINGS exchange, GOAWAY,
      graceful shutdown
- [x] 8 new `Flow:` `@testitem` units exercising window update edge
      cases (zero windows, overflow, stream vs connection window
      interactions)
- [x] `docs/src/streams.md`, `docs/src/connection.md`,
      `docs/src/flow-control.md` written with Role signalling sections
- [x] Public API distinguishes **server** and **client** roles
      explicitly via `is_client_initiated` / `is_server_initiated`
      helpers (client role IO pump deferred to M6)
- [x] 79 new exports across stream/connection/flow-control layers
- [x] 4 M0 test shim files deleted

**Exit criteria met**: all migrated gRPCServer.jl tests pass on
PureHTTP2.jl standalone (24,767 total); stateful layers documented.

---

## Milestone 4 — Reference Parity with Nghttp2Wrapper.jl ✅

**Status**: Completed (commit `a5df743`, version `0.2.0 → 0.3.0`)

Constitution Principle III requires cross-tests against `libnghttp2`
via Nghttp2Wrapper.jl. This milestone built that harness and
**operationally fulfilled Principle III for the server role**.

- [x] Nghttp2Wrapper.jl added as a **separate test env** at
      `test/interop/` (pinned to commit
      `a3dbdfb548c3d4bfbf4ddfce2a835a990f19dcc2`). Main env stays
      `[deps]`-empty per Principle I.
- [x] `test/interop/` with its own `Project.toml` declaring
      `julia = "1.12"` and the pinned Nghttp2Wrapper dep
- [x] 12 `Interop:` `@testitem` units covering the roadmap minimum set:
  - [x] Connection preface byte-for-byte (RFC 9113 §3.4)
  - [x] Frame type / flag / SETTINGS parameter constants
  - [x] HEADERS HPACK round-trip via
        `HpackDeflater`/`HpackInflater` with semantic-equivalent
        comparison on decoded header lists
  - [x] DATA frame with padding / END_STREAM variations
  - [x] WINDOW_UPDATE handshake + initial window change
  - [x] RST_STREAM error code propagation
  - [x] GOAWAY with last-stream-id across 3 error codes
  - [x] PING / PONG with 8-byte opaque data (RFC 9113 §6.7)
- [x] `docs/src/nghttp2-parity.md` with RFC 9113 section citations
- [x] New CI `interop` job pinned to Julia `1`
- [x] `test/runtests.jl` gains
      `filter = ti -> !startswith(ti.name, "Interop: ")` to keep
      interop items out of the main-env scan

**Plan deviation recorded**: error code constants item dropped because
Nghttp2Wrapper.jl does not export `NGHTTP2_NO_ERROR`-style constants;
error code wire values covered implicitly via the GOAWAY and
RST_STREAM items. 12 items instead of the planned 13.

**Exit criteria met**: interop test group green on Linux; 24,767 main
+ 24,872 interop (= 105 interop assertions).

---

## Milestone 5 — TLS & ALPN Integration (h2c first, h2 scaffolded) ✅

**Status**: Completed (commit `c874bce`, version `0.3.0 → 0.4.0`)

HTTP/2 over TCP (`h2c`) works without TLS, but real-world HTTP/2
needs ALPN-negotiated `h2`. The constitution permits
`OpenSSL`/`MbedTLS` for TLS only; protocol logic stays pure Julia.
**This milestone activated constitution Principle I's TLS/ALPN
carve-out via an optional package extension.**

**Scope pivot**: the milestone title mentions "TLS & ALPN" but
OpenSSL.jl at the target version does not export
`SSL_CTX_set_alpn_select_cb`, the server-side selection callback.
Since PureHTTP2.jl was server-role only before M6, full TLS+ALPN server
support could not land at M5. M5 therefore pivoted to:
**(a) h2c over real TCP** as the primary delivered capability, and
**(b) optional OpenSSL extension** scaffolded for forward compat
with M6's client-role work.

- [x] IO adapter contract defined: `read(io, n::Int)`,
      `write(io, bytes)`, `close(io)` — documented in
      `specs/006-tls-alpn-support/contracts/README.md`
- [x] New public function `serve_connection!(::HTTP2Connection, ::IO)`
      in `src/serve.jl` (~130 lines with docstring). Drives the server
      over any `Base.IO` transport satisfying the contract.
- [x] `[weakdeps] OpenSSL` + `[extensions] PureHTTP2OpenSSLExt` binding
      added to `Project.toml`. `[deps]` remains empty.
- [x] `ext/PureHTTP2OpenSSLExt.jl` package extension providing the
      single method
      `PureHTTP2.set_alpn_h2!(::OpenSSL.SSLContext, protocols::Vector{String}=["h2"])`.
      Converts the user-facing list into RFC 7301 §3.1 wire format
      (length-prefixed concatenation, 255-byte name cap) and calls
      `OpenSSL.ssl_set_alpn`.
- [x] 3 new `Transport:` main-env `@testitem` units: `IOBuffer`
      (split-IO wrapper), `Pipe` (paired `BufferStream`), stub
      (`set_alpn_h2!` has zero methods when OpenSSL is not loaded)
- [x] 2 new `Interop:` items in the interop env: `h2c live TCP
      handshake` (PureHTTP2.jl server vs Nghttp2Wrapper client) + ALPN
      extension loaded
- [x] `docs/src/tls.md` page with h2c vs h2, IO adapter contract,
      and current limitations
- [x] `upstream-bugs.md` entry for OpenSSL.jl's missing
      `SSL_CTX_set_alpn_select_cb` binding — server-side h2 TLS
      deferred pending upstream fix
- [x] `.gitignore` gained `!ext/` + `!ext/**/*.jl` allow entries so
      the new package extension file could be staged (gitallow pattern)

**Exit criteria partially met**: h2c end-to-end interops with
nghttp2 via the live TCP handshake item. Live ALPN-negotiated `h2`
end-to-end is **deferred to M6** because PureHTTP2.jl had no client role
at M5. Server-side h2 TLS remains **deferred to a future milestone**
pending the OpenSSL.jl upstream binding.

---

## Milestone 6 — Client Role Completion ✅

**Status**: Completed (commit `e9070d5`, version `0.4.0 → 0.5.0`)

gRPCServer.jl only exercised the server half of the state machine.
M6 rounded out the client half so PureHTTP2.jl is symmetric.
**This milestone operationally fulfilled constitution Principle III
for the client role** via a live TCP round trip against `libnghttp2`.

- [x] Client-role state transitions audited via 10 `Client:`
      `@testitem` units in `test/testitems_client.jl`
- [x] New public function `open_connection!(::HTTP2Connection, ::IO; ...)`
      in `src/client.jl` (~350 lines). Sends preface + initial
      SETTINGS (with `ENABLE_PUSH=0`), writes request
      HEADERS/DATA on odd stream ID, reads response, returns
      `NamedTuple{(:status, :headers, :body)}`. Handles graceful
      GOAWAY, `RST_STREAM`, `FRAME_SIZE_ERROR`, and unexpected
      `PUSH_PROMISE` per RFC 9113 §8.4.
- [x] `src/client.jl` includes a parallel client-role frame
      dispatcher (9 handlers) that **bypasses** the server-role
      `process_*_frame!` helpers in `src/connection.jl` — those
      embed server-side assumptions wrong for a client receiving a
      response. **Zero existing-src edits**; `src/PureHTTP2.jl` gains
      only `include("client.jl")` + `export open_connection!`.
- [x] Client-role `@testitem` units mirror the server tests:
      stream ID parity, BufferStream round-trip, END_STREAM on
      HEADERS, CONTINUATION reassembly, DATA body collection,
      RST_STREAM, GOAWAY (NO_ERROR + PROTOCOL_ERROR), PUSH_PROMISE
      rejection, FRAME_SIZE_ERROR enforcement
- [x] Cross-test: `Interop: h2c live TCP client` — PureHTTP2.jl client
      vs `Nghttp2Wrapper.HTTP2Server` over raw TCP. First live
      client-role cross-test; completes in ~2s (well under the
      10-second CI budget)
- [x] Cross-test: `Interop: set_alpn_h2! live TLS handshake` —
      promotes M5's `set_alpn_h2!` scaffold to a real TLS handshake
      against `Nghttp2Wrapper.HTTP2Server` with a self-signed cert
      fixture (`test/fixtures/selfsigned.{crt,key}`). The
      client-side ALPN wire-format conversion is verified
      end-to-end; the `h2` selection assertion is `@test_broken`
      pending the OpenSSL.jl `SSL_CTX_set_alpn_select_cb` upstream
      fix (M5 `upstream-bugs.md` entry unchanged).
- [x] `docs/src/client.md` page covering client vs server asymmetry,
      h2c + h2 worked examples, error handling, and current
      limitations. `docs/make.jl` pages array: 9 → 10 entries.

**Plan deviations recorded**:

- **New upstream-bugs entry**: Nghttp2Wrapper.jl's `HTTP2Server`
  handler dispatches requests but calls
  `nghttp2_submit_response2` with a `C_NULL` data provider, so the
  response body never crosses the wire. The live h2c client item
  cross-validates status + headers but asserts `isempty(result.body)`
  with an inline flip-to-equality TODO pending upstream fix.
- **TLS ALPN `@test_broken`**: the live handshake completes cleanly
  (proves the client-side wire format reaches OpenSSL and is
  accepted), but `h2` is not selected because
  `Nghttp2Wrapper.HTTP2Server` uses `OpenSSL.ssl_set_alpn` on a
  server context, which wraps the client-side
  `SSL_CTX_set_alpn_protos` — a no-op on a server context. The real
  fix is upstream in OpenSSL.jl.

**Exit criteria met**: PureHTTP2.jl drives a request/response exchange as
a client against nghttp2 without divergence on the parts that cross
the wire. 24,809 main + 24,937 interop assertions + 1 documented
broken.

---

## Milestone 7 — First Tagged Release `v0.1.0` ✅

**Status**: Completed (release commit on branch
`008-first-tagged-release`, merged to main and tagged `v0.1.0`
at release time; version `0.5.0 → 0.1.0`, 2026-04-12)

First tagged release of PureHTTP2.jl on the Julia General registry.
The `/speckit.specify` clarification round picked **Option A** —
retroactively bump `Project.toml` from `0.5.0` back to `0.1.0`
and tag `v0.1.0`. The backwards bump is permitted because
PureHTTP2.jl had never been registered; no downstream consumer had
resolved a version higher than `0.1.0`. See the
`## [0.1.0] — 2026-04-12` release section in `CHANGELOG.md` for
the "Version renumber note" with the SemVer justification.

- [x] Option A picked (tag `v0.1.0`, bump `Project.toml`
      `0.5.0 → 0.1.0`)
- [x] `CHANGELOG.md` `[Unreleased]` consolidated into a dated
      `## [0.1.0] — 2026-04-12` release section with Keep a
      Changelog canonical subsections (Added / Changed / Notes).
      Per-bullet "First delivered at Milestone N" attributions
      preserve the milestone narrative. `[Unreleased]` stub left
      in place for post-tag work.
- [x] `Project.toml` version line edited `0.5.0 → 0.1.0`.
      `[deps]` still empty; `[weakdeps]` / `[extensions]`
      unchanged from M6.
- [x] `.github/workflows/Documentation.yml` gains
      `permissions: contents: write` + `pull-requests: write` +
      `statuses: write`, plus a `push: tags: ['v*']` trigger.
      Documenter's `deploydocs` call in `docs/make.jl` already
      had the `GITHUB_ACTIONS` guard from Milestone 1; the
      workflow edit unblocks the deploy step.
- [x] `README.md` expanded from its 2-line stub to a 153-line
      landing page: title + 5 badges (CI, docs stable, docs dev,
      version, license), elevator pitch, installation snippet,
      h2c client worked example, "What's supported" bulleted
      list, "Current limitations" bulleted list, 6 in-repository
      links (changelog, roadmap, parity page, upstream bugs,
      license, docs), license note, acknowledgements section
      referencing gRPCServer.jl at commit `4abc0932`.
- [x] `ROADMAP.md` status snapshot table updated to mark M7
      completed. M7 section body updated to tick every
      checkbox.
- [ ] Registration in Julia's General registry via
      `@JuliaRegistrator register()` comment on the release
      commit — **deferred to manual post-merge step**. The bot
      is invoked interactively; the comment is posted on
      GitHub after the release PR merges to main and the
      `v0.1.0` tag is pushed.
- [ ] Upstream issues filed for the two outstanding
      `upstream-bugs.md` entries — **deferred to manual
      post-release follow-up** (T024 fallback in
      `specs/008-first-tagged-release/tasks.md`). The
      `Upstream link` fields in both entries now explain the
      filing deferral and will be updated to specific issue
      URLs in the next patch release.

**Exit criteria (partial)**: the release commit with all file
edits, tests green (24,809 main / 24,937 interop + 1 broken),
and warning-free docs build is ready for review. The
`Pkg.add("PureHTTP2")` installation verification from the spec is
a Phase C task that runs after the registry PR merges and
propagation completes — that is a post-milestone-timeline
task, not a blocker for the release commit itself.

**Deferred to post-M7 patch**: filing the two upstream GitHub
issues (T022 / T023 via manual creation), updating the
`Upstream link` fields in `upstream-bugs.md` to the resulting
issue URLs, and running the Phase C `Pkg.add("PureHTTP2")`
verification after registry propagation.

---

## Milestone 7.5 — Reseau.jl TLS backend ✅

**Status**: Completed (release commit on branch
`009-reseau-tls-backend`, merged to main and tagged `v0.2.0`
at release time; version `0.1.0 → 0.2.0`, 2026-04-13)

Server-side h2 over TLS — unblocked. PureHTTP2.jl ships a second
optional TLS backend via a new `ext/PureHTTP2ReseauExt.jl`
package extension that uses
[Reseau.jl](https://github.com/JuliaServices/Reseau.jl)
(pinned to v1.0.1 via the General registry). Reseau binds
`SSL_CTX_set_alpn_select_cb` internally at
`src/5_tls.jl:725-732` in v1.0.1, which is the exact upstream
gap in OpenSSL.jl that blocked server-side h2 at M5/M6/M7. The
`upstream-bugs.md` OpenSSL entry is flipped from `open` to
`worked-around via Reseau.jl`, and the M6 interop item whose
server-side ALPN assertion was `@test_broken` is repointed at a
Reseau TLS listener and flipped to a real `@test`.

- [x] Add `Reseau = "802f3686-..."` to `[weakdeps]` +
      `PureHTTP2ReseauExt = "Reseau"` to `[extensions]` in root
      `Project.toml`. `[deps]` still empty.
- [x] Export new `PureHTTP2.ALPN_H2_PROTOCOLS = ["h2"]` constant
      from `src/PureHTTP2.jl` as the shared canonical ALPN list
      for both `PureHTTP2OpenSSLExt` and `PureHTTP2ReseauExt`.
- [x] Export three new generic-function stubs from
      `src/PureHTTP2.jl`: `reseau_h2_server_config`,
      `reseau_h2_client_config`, `reseau_h2_connect`. Each has
      a full docstring explaining the constructor-style
      pattern and the symmetry-break with M5's `set_alpn_h2!`
      mutator.
- [x] Create `ext/PureHTTP2ReseauExt.jl` (~70 lines) with the
      three method implementations. Each method merges
      `alpn_protocols = PureHTTP2.ALPN_H2_PROTOCOLS` into the
      caller's kwargs and forwards to `Reseau.TLS.Config` or
      `Reseau.TLS.connect`. Zero bridging code — Reseau's
      `TLS.Conn <: IO` satisfies PureHTTP2.jl's IO adapter
      contract natively.
- [x] Add `Reseau` to `test/interop/Project.toml` `[deps]` +
      `Reseau = "1"` in `[compat]`. Registry-resolved (no
      `[sources]` pin — unlike Nghttp2Wrapper).
- [x] Two new `Interop:` `@testitem` units:
      - `Interop: h2 live TLS handshake (server-role via Reseau)`
        — 8 assertions, ~0.7s, verifies both sides'
        `connection_state(conn).alpn_protocol == "h2"` after
        a real TLS handshake through `PureHTTP2.reseau_h2_server_config`.
      - `Interop: ALPN helper with Reseau extension` — 13
        assertions, regression test for the package-extension
        auto-load flow.
- [x] Repoint M6's `Interop: set_alpn_h2! live TLS handshake`
      item: renamed to `... (Reseau server)`, server side
      swapped from `Nghttp2Wrapper.HTTP2Server` to a Reseau TLS
      listener built via `PureHTTP2.reseau_h2_server_config`,
      client side unchanged (OpenSSL.jl + `PureHTTP2.set_alpn_h2!`),
      `@test_broken selected == "h2"` flipped to `@test selected
      == "h2"`. **Interop broken counter drops 1 → 0.**
- [x] `docs/src/tls.md` restructured: new "TLS backends"
      section with a comparison table + two subsections
      (OpenSSL.jl, Reseau.jl), worked examples for both,
      `@docs` blocks for the three new helpers + the
      `ALPN_H2_PROTOCOLS` constant, symmetry-break narrative.
      "Current limitations" updated to remove the
      server-side h2 TLS blocker.
- [x] `docs/src/client.md` gains a new
      `### Over TLS (h2) via PureHTTP2ReseauExt` subsection with a
      worked example using `PureHTTP2.reseau_h2_connect` +
      `PureHTTP2.open_connection!`.
- [x] `upstream-bugs.md` OpenSSL.jl entry:
      `Status: open → worked-around via Reseau.jl`, full
      `Workaround` narrative rewrite.
- [x] Version `0.1.0 → 0.2.0`. Conventional commit prefix
      `feat(tls)`. Documenter build warning-free at v0.2.0.

**Exit criteria met**:
- Main-env test suite unchanged at 24,809 assertions (M7.5 is
  additive — no main-env items added).
- Interop-env test suite grows from 24,937 + 1 broken to
  **24,947 + 0 broken** (+10 assertions from the two new items
  and the repointed M6 item; −1 broken).
- Documenter build warning-free at v0.2.0.
- `src/*.jl` files from M0–M6 untouched except for the
  additive block in `src/PureHTTP2.jl` (one const + three function
  stubs + exports + docstrings).
- `ext/PureHTTP2OpenSSLExt.jl` untouched.
- `.gitignore` untouched.
- `docs/make.jl` pages array unchanged (still 10 entries).

---

## Rename milestone — `HTTP2` → `PureHTTP2` ✅

**Status**: Completed (version `0.2.0 → 0.3.0`, tag `v0.3.0`)

Rename the top-level Julia module, package name, and GitHub
repository from `HTTP2` to `PureHTTP2`. Mechanical sweep across
~35 files, zero functional change. The new name reflects the
package's defining property — a **pure-Julia** HTTP/2 transport
layer with an empty `[deps]` block (constitution Principle I) —
and de-conflicts with the long-standing JuliaWeb `HTTP.jl`
namespace.

**Scope**:

- [x] Root `Project.toml`: `name = "HTTP2"` → `"PureHTTP2"`,
      `version = "0.2.0"` → `"0.3.0"`, `[extensions]` table
      entries renamed `HTTP2OpenSSLExt`/`HTTP2ReseauExt` →
      `PureHTTP2OpenSSLExt`/`PureHTTP2ReseauExt`. **UUID
      unchanged** (`7d1e1b98-28e7-4969-8df9-5a308937986a`) —
      Option C from `/speckit.specify` clarification, permitted
      because `HTTP2` was never merged to General.
- [x] `src/HTTP2.jl` → `src/PureHTTP2.jl` via `git mv`,
      `module HTTP2` → `module PureHTTP2`, closing comment
      updated. `include(...)` wiring and `export` list
      byte-identical.
- [x] `ext/HTTP2OpenSSLExt.jl` → `ext/PureHTTP2OpenSSLExt.jl`
      and `ext/HTTP2ReseauExt.jl` → `ext/PureHTTP2ReseauExt.jl`
      via `git mv`; module declarations + `function
      PureHTTP2.<method>` bindings updated in lockstep so
      Julia's extension loader still discovers them.
- [x] 5 src doctest blocks (`frames.jl`, `hpack.jl`,
      `stream.jl`, `flow_control.jl`, `connection.jl`) and
      2 src docstring examples (`serve.jl`, `client.jl`)
      sweep `using HTTP2` → `using PureHTTP2` + qualified
      references.
- [x] 9 `test/testitems_*.jl` files in the main env +
      `test/interop/testitems_interop.jl` sweep `using HTTP2`,
      `HTTP2.<symbol>`, `names(HTTP2)`,
      `Base.get_extension(HTTP2, ...)`, and
      `:HTTP2{Open,Re}` → `PureHTTP2` variants.
- [x] `test/interop/Project.toml` `[deps]` entry name updated
      (UUID unchanged); `[sources]` and `[compat]` untouched.
- [x] `docs/Project.toml` `[deps]` entry renamed +
      `Pkg.develop(path=...)` re-resolved the docs env.
- [x] `docs/make.jl`: `using HTTP2` → `using PureHTTP2`,
      `modules`, `sitename`, `canonical`, and `repo` fields
      updated.
- [x] 10 `docs/src/*.md` pages sweep package-name narrative,
      `@docs HTTP2.<symbol>` → `@docs PureHTTP2.<symbol>` in
      `api.md`, and GitHub/Pages URL updates.
- [x] `README.md`, `upstream-bugs.md`, `ROADMAP.md`, and
      `CLAUDE.md` active-technologies section swept.
      Historical sections in `CHANGELOG.md` (v0.1.0, v0.2.0)
      and ROADMAP M0/M1 historical content preserved verbatim
      per research R11.
- [x] `CHANGELOG.md` gains a new `## [0.3.0] — 2026-04-13`
      section above `## [0.2.0]` with migration notes for
      downstream consumers (two mechanical edits: rename
      `Project.toml` dep, rename `using` declarations).

**Two carve-outs** (intentional non-renames):

- **Type names with `HTTP2` substring stay**:
  `HTTP2Connection`, `HTTP2Stream`, `HTTP2Server`, etc. refer
  to the HTTP/2 **protocol** per RFC 9113, not the package
  name. Type identifiers and exports are unchanged.
- **Function names with `h2` substring stay**:
  `set_alpn_h2!`, `reseau_h2_server_config`,
  `reseau_h2_client_config`, `reseau_h2_connect`,
  `ALPN_H2_PROTOCOLS`. `h2` is the ALPN protocol identifier
  per RFC 7301 §3.1 and should not be rewritten.

**Exit criteria met**:

- Main-env test suite: **24,809 pass / 0 fail / 0 broken**
  (byte-identical to v0.2.0).
- Interop-env test suite: **24,960 pass / 0 fail / 0 broken**
  (byte-identical to v0.2.0).
- Documenter build: **warning-free** at v0.3.0.
- Zero behavior change — no new symbols, no removed symbols,
  no method-table edits except the three-letter module prefix.
- `.gitignore`, `LICENSE`, `.github/workflows/*` untouched
  (operational scope audit).

**Operational tail** (post-merge, manual):

- Rename GitHub repository `s-celles/HTTP2.jl` →
  `s-celles/PureHTTP2.jl`; GitHub installs an automatic
  redirect so historical URLs in `CHANGELOG.md` continue to
  resolve.
- Cut tag `v0.3.0` from main.
- Submit to Julia General registry via
  `@JuliaRegistrator register()` bot comment (first-ever
  registration under the new name).

---

## Milestone 8 — First-class Request-Handler API ✅

**Status**: Completed (commit `317dd6e`, version `0.3.0 → 0.4.0`,
2026-04-13)

High-level server-side entry point so application code no longer
has to reimplement the frame loop or scan `conn.streams` manually
to serve HTTP/2 traffic. Shipped as a pure addition — the
low-level `serve_connection!` from M5 stays unchanged.

- [x] New public function
      `serve_with_handler!(handler, conn::HTTP2Connection, io::IO; ...)`
      in `src/handler.jl` (~490 lines with docstrings). Handler-first
      positional argument supports Julia's `do`-block syntax.
      Drives the same protocol plumbing as `serve_connection!`
      (preface, SETTINGS, PING, GOAWAY, flow control, frame
      read/write, `max_frame_size` enforcement) and additionally
      dispatches a handler callback once per completed request
      stream.
- [x] New public value types `Request` (immutable wrapper over
      `HTTP2Stream`) and `Response` (mutable accumulator) with 10
      handler-facing accessors/mutators: `request_method`,
      `request_path`, `request_authority`, `request_headers`,
      `request_header`, `request_body`, `request_trailers`,
      `set_status!`, `set_header!`, `write_body!` (two methods).
      Total: **13 new exports**.
- [x] Error-path contract: handler exceptions are caught inside
      `serve_with_handler!` — a `@warn` with the full backtrace is
      logged and the affected stream is reset with
      `RST_STREAM(INTERNAL_ERROR)`. The listen loop above the entry
      point is not killed by application bugs; other streams on
      the same connection continue to be served.
- [x] Auto-finalization contract: when the handler returns, the
      server emits the accumulated response frames (HEADERS + DATA
      frame(s) + END_STREAM) automatically. Handler code never has
      to signal end-of-stream.
- [x] Concurrency model: handlers are invoked **sequentially** in
      stream-close order by the same task that drives the frame
      loop. No per-stream `Task`, no write lock, no output queue —
      per-stream concurrency is a future extension reserved for
      M9+.
- [x] 8 new `Handler:`-prefixed `@testitem` units in
      `test/testitems_handler.jl` covering: buffered-body happy
      path (with byte-equivalence assertion against a hand-rolled
      `send_headers` + `send_data` emission — Principle III
      discharge for the "dispatch shim" claim), empty-body
      request, two interleaved streams on one connection, client
      disconnect before END_STREAM, handler omits explicit
      end-of-response, handler throws → RST_STREAM emission (with
      `@test_logs` capture), connection survives handler throw,
      and forward-compat docs inspection.
- [x] New `examples/echo-handler/` example (54-line `server.jl` +
      `README.md`) built on the new API. Sits alongside the
      preserved low-level `examples/echo/` as the high-level
      pedagogical companion. Reuses `examples/echo/client.jl`
      unchanged. `examples/echo/server.jl` is byte-identical
      pre/post feature; only its README is reframed from
      "temporary workaround" to intentional low-level showcase.
- [x] New `docs/src/handler.md` covering handler signature,
      `Request`/`Response` reference (`@docs` blocks for all 13
      symbols), error handling, concurrency model, and the
      **"Future: streaming"** subsection naming
      `Base.read(req, n)` and `flush(res)` as reserved
      forward-compat extension points for a streaming follow-up
      milestone. Wired into `docs/make.jl` between "TLS &
      transport" and "Client" — pages array grows 10 → 11.
- [x] Zero new `[deps]` — handler API uses only `Base` + `Sockets`
      (stdlib). Principle I strictly upheld. `[weakdeps]` and
      `[extensions]` unchanged.
- [x] `src/serve.jl` untouched — FR-019 "zero existing-src edits"
      steady state preserved. Only `src/PureHTTP2.jl` gains one
      `include("handler.jl")` line and 13 exports. The ~30-line
      frame-loop duplication between `serve_connection!` and
      `serve_with_handler!` is an explicit trade-off; extracting
      the shared loop into a helper is deferred to M9+.
- [x] `CHANGELOG.md` gains a `## [0.4.0] — 2026-04-13` section
      with `Added` and `Changed` subsections plus a "Forward
      compatibility" note about the reserved streaming extension
      points.

**Exit criteria met**:

- Main-env test suite: **24,857 pass / 0 fail / 0 broken**
  (baseline 24,809 + 48 new `Handler:` assertions across 8 items).
- Interop-env test suite: **25,007 pass / 1 pre-existing broken**
  (unchanged from baseline — the broken item is the latent
  `Transport: ALPN helper stub (no extension)` regression in the
  cross-env discovery path, not introduced by M8).
- Documenter build: warning-free at v0.4.0.
- `examples/echo-handler/server.jl` = 54 lines with zero
  frame-layer symbols (vs `examples/echo/server.jl` = 101 lines).
  Manual end-to-end run against `examples/echo/client.jl` "hello,
  echo" reproduces the expected `status = 200` / `body = hello,
  echo` output from `examples/echo/README.md`.
- Two clarified plan-level choices locked in: **error path**
  (RST_STREAM with `INTERNAL_ERROR`, not implicit `:status=500`)
  and **concurrency model** (sequential dispatch in stream-close
  order, not per-stream `Task`).

---

## Milestone 9 — Streaming response bodies via `flush(res)` + SSE example ✅

**Status**: Completed (commit `cebd74e`, version `0.4.0 → 0.5.0`,
2026-04-13)

Activate the M8 forward-compat reservation for **write-side
streaming**. Handlers can now emit response body bytes as HTTP/2
DATA frames incrementally via `Base.flush(res)` — before the
handler function returns — unblocking Server-Sent Events feeds,
long-running handlers with progress output, chunked downloads,
and any use case where the buffered-only M8 shape was a
structural limitation. Ships as a **pure addition** on top of
M8 with zero breaking changes.

- [x] New method `Base.flush(res::Response)` in
      `src/handler.jl` (~140 lines added including ~100-line
      docstring). Lazy HEADERS emission on first call
      (FR-003); non-terminal DATA emission (never sets
      `END_STREAM` — finalize does); buffer-clear after each
      call so `write_body!` starts fresh; empty-body flush =
      HEADERS only (first call) or total no-op (subsequent);
      `res.finalized` guard + `res.io === nothing` defensive
      guard; returns `res` for chaining. Not exported — reached
      via normal `flush(...)` dispatch because `Base.flush` is
      already in every Julia scope.
- [x] `Response` mutable struct gains two new internal fields:
      `io::Union{IO, Nothing}` (transport reference, set by
      `serve_with_handler!` before handler invocation so flush
      can reach the wire from inside the handler) and
      `headers_sent::Bool` (commit tracker set by the first
      flush). The public 2-arg constructor
      `Response(conn::HTTP2Connection, stream_id::UInt32)`
      signature is unchanged — both new fields default-initialize
      to `nothing` and `false` respectively.
- [x] `set_status!` and `set_header!` gain a new no-op branch:
      when the response HEADERS have already been emitted on
      the wire (by a prior `flush(res)` call), these mutators
      log `@warn "Response headers already on the wire"` and
      return `res` unchanged. Handlers that never call `flush`
      (the v0.4.0 buffered-only shape) see no change — the new
      branch is additive. `write_body!` stays unchanged and
      still appends to the now-emptied buffer for the next
      flush.
- [x] `_finalize_response!` branches on `res.headers_sent`:
      **Branch A** (`false`, buffered path) is byte-identical
      to M8; **Branch B** (`true`, streaming path) skips
      HEADERS and emits either a terminal DATA frame with
      `END_STREAM` (body non-empty) or a zero-length DATA
      frame with `END_STREAM` (body empty — wire-legal per
      RFC 9113 §6.1). One bug surfaced during implementation:
      `send_data_frames`'s inner loop is `while remaining > 0`,
      so an empty body produces no frames at all — the
      streaming finalize path builds the terminal frame
      explicitly via
      `data_frame(stream_id, UInt8[]; end_stream=true)` and
      updates stream state with `send_data!(stream, 0, true)`.
- [x] 8 new `Handler:`-prefixed `@testitem` units appended to
      `test/testitems_handler.jl` (~580 lines of test code):
      (1) single flush emits DATA before handler return —
      cooperative `Channel` coordination for deterministic
      timing without wall-clock fragility; (2) multiple flushes
      emit distinct DATA frames; (3) buffered-only handler
      wire-identical to M8 — byte-equivalence regression guard
      against a hand-rolled `send_headers`+`send_data` probe
      emission; (4) `set_status!` post-flush no-op with warn;
      (5) `set_header!` post-flush no-op with warn;
      (6) `write_body!` still works post-flush — regression
      surface for buffer reuse; (7) flush then throw emits
      `RST_STREAM` — verifies HEADERS + DATA(partial) +
      `RST_STREAM(INTERNAL_ERROR)`, no terminal `END_STREAM`;
      (8) connection survives streaming handler throw — second
      interleaved stream succeeds normally.
- [x] M8 `Handler: forward-compat extension points documented`
      inspection testitem updated: asserts the live
      `## Streaming` section + `Base.flush` reference while
      preserving the `Base.read(req` read-side reservation.
- [x] New `examples/sse/` directory: `server.jl` (53 lines,
      zero frame-layer symbols) emits 5 `data: tick N\n\n`
      events at 1-second intervals on path `/ticks` using
      `flush(res)` + `sleep(1.0)` in a loop; 404 on other
      paths uses the buffered path (doubling as a live
      FR-009 regression exercise). `README.md` with
      `curl -N --http2-prior-knowledge` verification recipe,
      explanation of the generic-flush-primitive-vs-SSE-client-
      protocol distinction, variants for different tick counts
      or infinite streams. No Julia client — curl serves as
      the streaming client because `open_connection!` blocks
      until `END_STREAM` and would hide streaming on the read
      side. A Julia-native streaming client is deferred to
      the `Base.read(req, n)` extension point milestone.
- [x] `docs/src/handler.md` "Future: streaming" subsection
      promoted to a live `## Streaming` top-level section
      (~120 lines replacing ~24 lines of M8 stub) containing
      prose, a worked example sourced from
      `examples/sse/server.jl`, an
      `@docs Base.flush(::PureHTTP2.Response)` block rendering
      the in-source docstring, "Lazy HEADERS emission"
      subsection with code example, "Error path under
      streaming" subsection clarifying the inherent
      "bytes-on-wire cannot be rolled back" property, and
      preserved "Future: request-side streaming" subsection
      for the still-reserved `Base.read(req::Request, n::Integer)`
      extension point. `docs/make.jl` pages array is
      **unchanged** (no new docs page).
- [x] Zero new `[deps]` — streaming primitive uses only
      `Base` + M8 helpers. Principle I strictly upheld.
      `[weakdeps]` / `[extensions]` unchanged (OpenSSL +
      Reseau, both TLS backends).
- [x] `src/serve.jl` untouched — FR-020 "zero existing-src
      edits outside `src/handler.jl`" steady state preserved.
      `src/PureHTTP2.jl` also untouched (no new exports —
      `Base.flush` dispatch works without PureHTTP2 re-exporting
      the name).
- [x] `CHANGELOG.md` gains a `## [0.5.0] — 2026-04-13` section
      with `### Added` (new `Base.flush` method + `examples/sse/`
      + 8 new testitems), `### Changed` (updated mutator
      contracts + docs promotion + `Response` fields +
      `_finalize_response!` branch), and "Forward compatibility"
      note about the still-reserved `Base.read(req, n)`
      read-side streaming.

**Exit criteria met**:

- Main-env test suite: **24,910 pass / 0 fail / 0 broken**
  (baseline 24,857 + 53 new streaming assertions across 8 new
  `Handler:` items; handler testitem count grows 8 → 16).
- Interop-env test suite: **25,060 pass / 1 pre-existing broken**
  (same `Transport: ALPN helper stub (no extension)` item as
  baseline — not regressed; the 53-item delta vs. M8's 25,007
  is the new testitems_handler.jl items auto-discovered in the
  cross-env test runner, **zero new `Interop:`-prefixed items
  added**).
- Documenter build: warning-free at v0.5.0. The new
  `@docs Base.flush(::PureHTTP2.Response)` block resolves
  without a "missing docstring" warning.
- Manual SSE verification: `curl -N --http2-prior-knowledge
  http://127.0.0.1:8787/ticks` against
  `examples/sse/server.jl` shows all 5 ticks arriving
  progressively over ~5 seconds with ~1-second gaps between
  them, curl exits cleanly with status 0.
- `examples/sse/server.jl` is 53 lines with **zero frame-layer
  symbols** (`grep` check empty).
- Three plan-level choices locked in:
  (1) **terminal frame shape** = zero-length DATA +
  `END_STREAM` on finalize-after-flush when body empty;
  (2) **no `end_stream` kwarg** on `flush(res)` — always
  non-terminal emission, single positional argument;
  (3) **SSE unknown-path response** = standard `404` with
  `text/plain` buffered body (doubles as a live FR-009
  buffered-path exercise in the same file).

---

## Milestone 10 — gRPCServer.jl Reverse Integration

**Status**: Not started
**Target version**: → `v0.6.0`

Close the loop: make gRPCServer.jl consume PureHTTP2.jl as a dependency
instead of vendoring its own copy. This is the acceptance test for
the whole extraction.

- [ ] Replace `gRPCServer/src/http2/**` with `import PureHTTP2` and delete
      the vendored modules
- [ ] Run gRPCServer.jl's full unit + integration + interop test
      suites against PureHTTP2.jl
- [ ] Evaluate whether gRPCServer.jl can build on top of
      `serve_with_handler!` (M8) directly — the handler-callback
      shape is a natural fit for gRPC unary / server-streaming
      methods, and adopting it removes another layer of
      frame-loop code gRPCServer.jl would otherwise maintain
- [ ] File any regressions discovered as issues on PureHTTP2.jl (not
      gRPCServer.jl); fix them here and release a patch if needed
- [ ] Cut PureHTTP2.jl minor-bump release once gRPCServer.jl is fully
      swapped over
- [ ] Consider re-evaluating the `src/stream.jl` gRPC-helpers
      layering concern recorded in `upstream-bugs.md` — with the
      reverse integration in place, moving those helpers from
      PureHTTP2.jl to a gRPC adapter becomes straightforward

**Exit criteria**: gRPCServer.jl's CI is green against the latest
PureHTTP2.jl release with its HTTP/2 sources removed.

---

## Future / Post-M10

Not scheduled — to be triaged after M10 lands. Items are grouped
by theme for readability; priority within each group is TBD.

### Handler API follow-ups (from M8 / M9)

The M8 request-handler API + M9 write-side streaming leave the
read side (incremental request-body reads) reserved for a
follow-up. The items below are **pure additions** — no symbol
shipped in v0.4.0 / v0.5.0 will change signature, return type,
or semantics when they land.

- **Streaming request bodies** (still deferred) —
  incremental `Base.read(req::Request, n::Integer) -> Vector{UInt8}`
  so handlers can start processing the request body before
  `END_STREAM` arrives. Complement of the buffered
  `request_body(req)` accessor. Forward-compat extension point
  reserved in M8 and still reserved after M9 — only the write
  side shipped. When it lands, existing handlers calling
  `request_body(req)` will continue to work unchanged; the new
  method is a pure addition, not a replacement. See
  `docs/src/handler.md` "Future: request-side streaming"
  subsection for the current status.
- **Streaming response bodies** — **SHIPPED at M9** as
  `Base.flush(res::Response)`. See Milestone 9 above and
  `examples/sse/` for the canonical use case.
- **Streaming client reading** — a Julia-native client that
  prints incoming DATA frames as they arrive (instead of
  waiting for `END_STREAM` like `open_connection!` does).
  Deferred because it depends on M9+ read-side client streaming,
  which is not yet shipped. Today's SSE example uses `curl -N`
  as the streaming client; once a Julia client exists, an
  `examples/sse/client.jl` companion could ship alongside it.
- **Per-stream `Task` concurrency** for `serve_with_handler!` —
  opt-in dispatch model so a handler that blocks on long-running
  IO (database query, upstream HTTP call) does not stall other
  streams on the same connection. Requires a write lock or frame
  output channel consumed by a dedicated writer task. Additive
  — the sequential default stays unchanged.
- **Shared frame-loop refactor** — extract the read/write loop
  body from `src/serve.jl` into a helper consumed by both
  `serve_connection!` and `serve_with_handler!`. Retires the
  ~30-line duplication in `src/handler.jl` introduced at M8 to
  preserve the FR-019 "zero existing-src edits" steady state.
  Pure internal refactor; public API unchanged.
- **Formal interop cross-test for `serve_with_handler!`** — M8's
  plan discharged Principle III via a main-env byte-equivalence
  assertion against a hand-rolled `send_headers` + `send_data`
  emission (`plan.md` Complexity Tracking). A proper
  `Interop: h2c handshake via handler API` item in
  `test/interop/testitems_interop.jl` is a cleaner long-term
  discharge once there is non-shim behavior to validate
  (streaming, per-stream Tasks, or content-length auto-detect
  would all be triggers).
- **`content-length` auto-detection** (opt-in) — M8 deliberately
  does NOT set `content-length` automatically to preserve
  forward-compat with streaming responses whose total length is
  unknown at finalize time. An opt-in helper (e.g., a
  `set_content_length=true` kwarg on `serve_with_handler!` or a
  `finalize_content_length!(res)` utility) would reduce
  boilerplate for buffered handlers. Non-breaking addition.
- **Stream-state-aware mutator no-ops** — if the peer sends
  `RST_STREAM` while a handler is mid-execution, subsequent
  `set_status!` / `set_header!` / `write_body!` calls currently
  succeed locally and then get silently dropped at finalize
  time. They should become no-ops with a `@warn "stream was
  reset by peer"` when the underlying `HTTP2Stream` is in the
  `CLOSED` state, matching the existing "Response already
  finalized" pattern in `src/handler.jl`.
- **Handler middleware patterns** — documentation + worked
  examples of composable `handler(req, res)` wrappers for
  logging (`request received` / `response sent` with timing),
  auth (check `authorization` header → set 401 or delegate),
  CORS (add `access-control-*` headers), and request ID
  injection. No new library code — just a cookbook page
  demonstrating the composition pattern on top of the M8
  primitives.
- **Trailer-producing handlers** — M8 exposes `request_trailers`
  for reads but the `Response` type has no equivalent for
  emitting trailers on the response side. Adding
  `set_trailer!(res, name, value)` + trailer emission in
  `_finalize_response!` would complete the read/write symmetry.
  Useful for gRPC server-side status trailers (`grpc-status`,
  `grpc-message`).

### New example directories

Each of these would live under `examples/` and ship with its own
`server.jl` + `README.md`, following the shape established by
`examples/echo/` and `examples/echo-handler/`.

- **`examples/json-api/`** — small REST-ish JSON endpoint built
  on `serve_with_handler!`. Demonstrates routing by
  `request_path`, `application/json` content-type handling,
  reading a JSON request body, writing a JSON response body.
  Reuses `JSON.jl` from the test-target deps as an example-only
  dependency in a new `examples/json-api/Project.toml`.
- **`examples/static-files/`** — serving static files from a
  directory. Demonstrates MIME-type detection via file
  extension, `content-length` from `stat()`, 404 on missing
  files, 405 on non-GET methods. Good showcase for the
  read-side of `Request` (method/path inspection) and the
  write-side of `Response` (file-streamed body, content-type,
  cache headers).
- **`examples/echo-h2-tls/`** — combines
  `reseau_h2_server_config` (M7.5) + `serve_with_handler!` (M8)
  for a full h2-over-TLS demo. Requires a test cert fixture (can
  reuse `test/fixtures/selfsigned.{crt,key}` from M6). The
  canonical "production-shaped" server example — what real-world
  PureHTTP2.jl consumers will most often copy-paste.
- **`examples/router/`** — tiny routing layer over
  `request_method` + `request_path` dispatching to per-route
  handler functions. Demonstrates the handler-as-composition
  pattern by wrapping multiple per-route `handler(req, res)`
  functions into a single dispatching top-level handler. No
  library changes — this is a pure documentation example.
- **`examples/graceful-shutdown/`** — catching `SIGTERM` /
  `SIGINT` (via `Base.atexit` or a `ccall` to `signal`),
  emitting a GOAWAY frame, draining in-flight handlers before
  closing the listen socket. The current echo examples use a
  hard `Ctrl-C` stop — a proper shutdown demo is a useful
  complement for production deployments.
- **`examples/trailers/`** — once response-side trailer emission
  lands (see Handler API follow-ups above), a minimal example
  showing how to emit `grpc-status`/`grpc-message`-shaped
  trailers. Before that lands, a read-side-only example
  showcasing `request_trailers` on a handler that inspects
  client-sent trailers is also viable.

### Protocol & performance (unchanged from prior ROADMAPs)

- **Multi-request client sessions** over one connection — M6
  ships a single-request API; long-lived sessions with stream
  multiplexing are a separate concern.
- **Affirmative server push handling** — M6/M8 only ship the
  negative `ENABLE_PUSH=0` test; accepting, processing, or
  explicitly refusing pushed streams is out of scope.
- **Stream priority** (RFC 9113 §5.3) beyond best-effort.
- **Extensible SETTINGS** per RFC 7540 §6.5.2.
- **Performance benchmarking harness** (`benchmark/`) with a
  baseline vs nghttp2 throughput comparison. The handler API
  (M8) is a natural measurement target — allocation per
  request, frames per second per connection.
- **Fuzz harness** for the frame decoder (pure-Julia, e.g.
  `Supposition.jl`).
- **Allocation-free hot paths** for DATA frame forwarding.

### Documentation

- **Migration guide** from low-level `serve_connection!` (M5) to
  the high-level `serve_with_handler!` (M8), targeted at any
  gRPCServer.jl-era consumer who already has manual frame-loop
  code. A short `docs/src/migration.md` page with before/after
  diffs.
- **Performance cookbook** — once benchmarks exist, document the
  memory and latency characteristics of the handler API and
  when to fall back to `serve_connection!` for raw-frame
  access.
- **macOS / Windows interop CI** — deferred across M4–M6
