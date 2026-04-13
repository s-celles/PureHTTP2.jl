# Roadmap

This document outlines the planned milestones for HTTP2.jl, a pure Julia
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
| M8        | → `v0.3.0`      | Not started    |           |                        |

**Principle III (Specification Conformance & Reference Parity)** is
operationally fulfilled for **server role** (M4, deepened at M5),
**client role** (M6), and **server-side h2 over TLS** (M7.5 via
Reseau.jl).

**Deferred upstream** (tracked in `upstream-bugs.md`):

- OpenSSL.jl: `SSL_CTX_set_alpn_select_cb` binding missing —
  **no longer blocking HTTP2.jl** as of M7.5 (worked around via
  Reseau.jl). Still a valuable upstream addition for users who
  want the OpenSSL-only code path without Reseau as a second
  dependency.
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

Stood up HTTP2.jl as a real Julia package so the extracted code could
be developed in isolation.

- [x] `Project.toml` with `name = "HTTP2"`, UUID
      `7d1e1b98-28e7-4969-8df9-5a308937986a`, `[compat]` entries, and
      minimum Julia version `1.10`
- [x] `src/HTTP2.jl` root module `include`ing the five extracted files
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
HTTP2.jl standalone (24,767 total); stateful layers documented.

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
Since HTTP2.jl was server-role only before M6, full TLS+ALPN server
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
- [x] `[weakdeps] OpenSSL` + `[extensions] HTTP2OpenSSLExt` binding
      added to `Project.toml`. `[deps]` remains empty.
- [x] `ext/HTTP2OpenSSLExt.jl` package extension providing the
      single method
      `HTTP2.set_alpn_h2!(::OpenSSL.SSLContext, protocols::Vector{String}=["h2"])`.
      Converts the user-facing list into RFC 7301 §3.1 wire format
      (length-prefixed concatenation, 255-byte name cap) and calls
      `OpenSSL.ssl_set_alpn`.
- [x] 3 new `Transport:` main-env `@testitem` units: `IOBuffer`
      (split-IO wrapper), `Pipe` (paired `BufferStream`), stub
      (`set_alpn_h2!` has zero methods when OpenSSL is not loaded)
- [x] 2 new `Interop:` items in the interop env: `h2c live TCP
      handshake` (HTTP2.jl server vs Nghttp2Wrapper client) + ALPN
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
end-to-end is **deferred to M6** because HTTP2.jl had no client role
at M5. Server-side h2 TLS remains **deferred to a future milestone**
pending the OpenSSL.jl upstream binding.

---

## Milestone 6 — Client Role Completion ✅

**Status**: Completed (commit `e9070d5`, version `0.4.0 → 0.5.0`)

gRPCServer.jl only exercised the server half of the state machine.
M6 rounded out the client half so HTTP2.jl is symmetric.
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
      response. **Zero existing-src edits**; `src/HTTP2.jl` gains
      only `include("client.jl")` + `export open_connection!`.
- [x] Client-role `@testitem` units mirror the server tests:
      stream ID parity, BufferStream round-trip, END_STREAM on
      HEADERS, CONTINUATION reassembly, DATA body collection,
      RST_STREAM, GOAWAY (NO_ERROR + PROTOCOL_ERROR), PUSH_PROMISE
      rejection, FRAME_SIZE_ERROR enforcement
- [x] Cross-test: `Interop: h2c live TCP client` — HTTP2.jl client
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

**Exit criteria met**: HTTP2.jl drives a request/response exchange as
a client against nghttp2 without divergence on the parts that cross
the wire. 24,809 main + 24,937 interop assertions + 1 documented
broken.

---

## Milestone 7 — First Tagged Release `v0.1.0` ✅

**Status**: Completed (release commit on branch
`008-first-tagged-release`, merged to main and tagged `v0.1.0`
at release time; version `0.5.0 → 0.1.0`, 2026-04-12)

First tagged release of HTTP2.jl on the Julia General registry.
The `/speckit.specify` clarification round picked **Option A** —
retroactively bump `Project.toml` from `0.5.0` back to `0.1.0`
and tag `v0.1.0`. The backwards bump is permitted because
HTTP2.jl had never been registered; no downstream consumer had
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
`Pkg.add("HTTP2")` installation verification from the spec is
a Phase C task that runs after the registry PR merges and
propagation completes — that is a post-milestone-timeline
task, not a blocker for the release commit itself.

**Deferred to post-M7 patch**: filing the two upstream GitHub
issues (T022 / T023 via manual creation), updating the
`Upstream link` fields in `upstream-bugs.md` to the resulting
issue URLs, and running the Phase C `Pkg.add("HTTP2")`
verification after registry propagation.

---

## Milestone 7.5 — Reseau.jl TLS backend ✅

**Status**: Completed (release commit on branch
`009-reseau-tls-backend`, merged to main and tagged `v0.2.0`
at release time; version `0.1.0 → 0.2.0`, 2026-04-13)

Server-side h2 over TLS — unblocked. HTTP2.jl ships a second
optional TLS backend via a new `ext/HTTP2ReseauExt.jl`
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
      `HTTP2ReseauExt = "Reseau"` to `[extensions]` in root
      `Project.toml`. `[deps]` still empty.
- [x] Export new `HTTP2.ALPN_H2_PROTOCOLS = ["h2"]` constant
      from `src/HTTP2.jl` as the shared canonical ALPN list
      for both `HTTP2OpenSSLExt` and `HTTP2ReseauExt`.
- [x] Export three new generic-function stubs from
      `src/HTTP2.jl`: `reseau_h2_server_config`,
      `reseau_h2_client_config`, `reseau_h2_connect`. Each has
      a full docstring explaining the constructor-style
      pattern and the symmetry-break with M5's `set_alpn_h2!`
      mutator.
- [x] Create `ext/HTTP2ReseauExt.jl` (~70 lines) with the
      three method implementations. Each method merges
      `alpn_protocols = HTTP2.ALPN_H2_PROTOCOLS` into the
      caller's kwargs and forwards to `Reseau.TLS.Config` or
      `Reseau.TLS.connect`. Zero bridging code — Reseau's
      `TLS.Conn <: IO` satisfies HTTP2.jl's IO adapter
      contract natively.
- [x] Add `Reseau` to `test/interop/Project.toml` `[deps]` +
      `Reseau = "1"` in `[compat]`. Registry-resolved (no
      `[sources]` pin — unlike Nghttp2Wrapper).
- [x] Two new `Interop:` `@testitem` units:
      - `Interop: h2 live TLS handshake (server-role via Reseau)`
        — 8 assertions, ~0.7s, verifies both sides'
        `connection_state(conn).alpn_protocol == "h2"` after
        a real TLS handshake through `HTTP2.reseau_h2_server_config`.
      - `Interop: ALPN helper with Reseau extension` — 13
        assertions, regression test for the package-extension
        auto-load flow.
- [x] Repoint M6's `Interop: set_alpn_h2! live TLS handshake`
      item: renamed to `... (Reseau server)`, server side
      swapped from `Nghttp2Wrapper.HTTP2Server` to a Reseau TLS
      listener built via `HTTP2.reseau_h2_server_config`,
      client side unchanged (OpenSSL.jl + `HTTP2.set_alpn_h2!`),
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
      `### Over TLS (h2) via HTTP2ReseauExt` subsection with a
      worked example using `HTTP2.reseau_h2_connect` +
      `HTTP2.open_connection!`.
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
  additive block in `src/HTTP2.jl` (one const + three function
  stubs + exports + docstrings).
- `ext/HTTP2OpenSSLExt.jl` untouched.
- `.gitignore` untouched.
- `docs/make.jl` pages array unchanged (still 10 entries).

---

## Milestone 8 — gRPCServer.jl Reverse Integration

**Status**: Not started
**Target version**: → `v0.3.0`

Close the loop: make gRPCServer.jl consume HTTP2.jl as a dependency
instead of vendoring its own copy. This is the acceptance test for
the whole extraction.

- [ ] Replace `gRPCServer/src/http2/**` with `import HTTP2` and delete
      the vendored modules
- [ ] Run gRPCServer.jl's full unit + integration + interop test
      suites against HTTP2.jl
- [ ] File any regressions discovered as issues on HTTP2.jl (not
      gRPCServer.jl); fix them here and release a patch if needed
- [ ] Cut HTTP2.jl minor-bump release once gRPCServer.jl is fully
      swapped over
- [ ] Consider re-evaluating the `src/stream.jl` gRPC-helpers
      layering concern recorded in `upstream-bugs.md` — with the
      reverse integration in place, moving those helpers from
      HTTP2.jl to a gRPC adapter becomes straightforward

**Exit criteria**: gRPCServer.jl's CI is green against the latest
HTTP2.jl release with its HTTP/2 sources removed.

---

## Future / Post-M8

Not scheduled — to be triaged after M8 lands:

- **Multi-request client sessions** over one connection — M6 ships a
  single-request API; long-lived sessions with stream multiplexing
  are a separate concern
- **Affirmative server push handling** — M6 only ships the negative
  `ENABLE_PUSH=0` test; accepting, processing, or explicitly
  refusing pushed streams is out of scope
- **Multi-frame request bodies** — M6's `request_body` is a single
  `Vector{UInt8}` written as one DATA frame; chunked/streamed
  uploads are deferred
- **Server-side h2 TLS** — blocked on the OpenSSL.jl upstream
  `SSL_CTX_set_alpn_select_cb` binding (tracked in `upstream-bugs.md`)
- **Stream priority** (RFC 9113 §5.3) beyond best-effort
- **Extensible SETTINGS** per RFC 7540 §6.5.2
- **Performance benchmarking harness** (`benchmark/`) with a
  baseline vs nghttp2 throughput comparison
- **Fuzz harness** for the frame decoder (pure-Julia, e.g.
  `Supposition.jl`)
- **Allocation-free hot paths** for DATA frame forwarding
- **macOS / Windows interop CI** — deferred across M4–M6
