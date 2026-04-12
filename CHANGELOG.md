# Changelog

All notable changes to HTTP2.jl will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and HTTP2.jl adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (Milestone 5)

- **Milestone 5 — TLS & ALPN integration (h2c first, h2 scaffolded)**.
  HTTP2.jl gains its first IO-driven server entry point and the
  groundwork for optional TLS/ALPN support via a Julia package
  extension. **This milestone activates constitution Principle I's
  TLS/ALPN carve-out** — and activates it via an *optional* package
  extension (`[weakdeps]` + `[extensions]`), not a hard dependency,
  so `[deps]` stays empty.
- New public function `HTTP2.serve_connection!(conn::HTTP2Connection,
  io::IO; max_frame_size::Int = DEFAULT_MAX_FRAME_SIZE)` in
  `src/serve.jl`. Drives a server-role HTTP/2 connection over any
  `Base.IO` transport that satisfies the IO adapter contract
  (see `specs/006-tls-alpn-support/contracts/README.md`). Handles
  the client preface, server preface write-back, frame read loop
  with `max_frame_size` enforcement (RFC 9113 §6.5.2,
  `FRAME_SIZE_ERROR` on overlong frames), graceful EOF detection,
  and write-back of response frames. Transports cross-tested at
  M5: `Base.IOBuffer` (with a split-IO wrapper),
  `Base.BufferStream`, `Sockets.TCPSocket` (loopback live).
- New package extension `ext/HTTP2OpenSSLExt.jl` providing the
  single method
  `HTTP2.set_alpn_h2!(ctx::OpenSSL.SSLContext,
  protocols::Vector{String} = ["h2"])`. Registers the ALPN
  protocol list on an OpenSSL.jl TLS context via `ssl_set_alpn`
  after converting the user-facing `Vector{String}` into the
  RFC 7301 §3.1 wire format (length-prefixed concatenation,
  max 255 bytes per protocol name — `ArgumentError` on violation).
  The extension loads automatically via `Base.get_extension` when
  both HTTP2 and OpenSSL are in the environment; without OpenSSL,
  `HTTP2.set_alpn_h2!` exists as a generic function with zero
  methods and calling it throws `MethodError` by design.
- New `[weakdeps]` + `[extensions]` sections in `Project.toml`
  binding `HTTP2OpenSSLExt = "OpenSSL"`. `[deps]` remains empty
  (Principle I preserved).
- New `src/HTTP2.jl` declarations: `include("serve.jl")`, the
  `function set_alpn_h2! end` stub with a docstring documenting
  the extension pattern + limitations, and two new exports
  (`serve_connection!`, `set_alpn_h2!`) in a new "Milestone 5:
  transport layer" export block.
- 3 new `Transport:` `@testitem` units in the main env at
  `test/testitems_transport.jl`: `serve_connection! with IOBuffer`
  (split-IO wrapper, asserts SETTINGS + SETTINGS ACK + PING ACK
  appear in server responses), `serve_connection! with Pipe`
  (paired `BufferStream` instances, blocking-read code path,
  client-task-driven handshake), `ALPN helper stub (no extension)`
  (asserts zero methods + `MethodError` when OpenSSL is not
  loaded — guards Principle I's "no OpenSSL dep when not loaded"
  guarantee).
- 2 new `Interop:` `@testitem` units in `test/interop/testitems_interop.jl`:
  `h2c live TCP handshake` (first live cross-test of
  `serve_connection!` over a real `Sockets.TCPSocket` against a
  Nghttp2Wrapper.jl client — preface exchange, server SETTINGS,
  SETTINGS ACK, PING round-trip, graceful GOAWAY under 10 s per
  SC-005), `ALPN helper with OpenSSL extension` (verifies the
  extension loads automatically when OpenSSL.jl is in the env
  transitively via Nghttp2Wrapper, exercises
  `set_alpn_h2!(::OpenSSL.SSLContext)` for single-protocol and
  multi-protocol forms, verifies 255-byte bound enforcement).
- New `docs/src/tls.md` page covering: h2c vs h2 comparison with
  RFC 9113 §3 citations, the IO adapter contract (3 required
  `Base.IO` methods in a table), the canonical h2c server loop
  over `Sockets`, usage of the optional OpenSSL extension, and a
  "Current limitations" section naming the server-side ALPN gap
  and the Milestone 6 client-role deferral. `docs/make.jl` pages
  array grows from 8 to 9 entries with "TLS & transport"
  inserted between "Interop parity" and "API Reference".
- New entry in `upstream-bugs.md` (newest-first ordering) for
  OpenSSL.jl's missing `SSL_CTX_set_alpn_select_cb` binding, with
  full Package/Issue/Upstream link/Impact/Workaround/Status
  fields and an explicit note that **no ccall workaround is
  attempted locally** (Principle I).

### Changed (Milestone 5)

- Version bump `0.3.0 → 0.4.0` (minor: new public API surface
  `serve_connection!` + generic `set_alpn_h2!`, no breaking
  changes to M0–M4 exports).
- `src/HTTP2.jl` gains the three permitted additions listed
  above; no changes to `src/frames.jl`, `src/hpack.jl`,
  `src/stream.jl`, `src/flow_control.jl`, or
  `src/connection.jl` (FR-014 not triggered at M5).

### Notes (Milestone 5)

- **Server-side h2 TLS is deferred** pending upstream OpenSSL.jl
  binding — see the new `upstream-bugs.md` entry and the
  "Current limitations" section of `docs/src/tls.md`. The client-
  side `set_alpn_h2!` helper is a forward-compatible scaffold
  awaiting Milestone 6's client-role code for its live cross-test.
- The `interop` CI job from M4 is unchanged. TestItemRunner's
  scan automatically picks up the new `Interop:` items in
  `test/interop/testitems_interop.jl`.

### Added (Milestone 4)

- **Milestone 4 — Reference parity with Nghttp2Wrapper.jl**.
  HTTP2.jl's wire behaviour is now cross-tested against
  `libnghttp2` (via
  [Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl)
  pinned to commit `a3dbdfb548c3d4bfbf4ddfce2a835a990f19dcc2`)
  on every push via a dedicated CI job. **This is the
  milestone that operationally fulfills constitution
  Principle III (Specification Conformance & Reference
  Parity).**
- Separate test environment at `test/interop/` with its own
  `Project.toml` declaring `julia = "1.12"` (Nghttp2Wrapper.jl's
  minimum). The main `Pkg.test()` flow on Julia 1.10+ is
  unaffected — interop items are filtered out of the main
  suite's discovery via a `filter` kwarg in `test/runtests.jl`.
- 12 native `Interop:` `@testitem` units in
  `test/interop/testitems_interop.jl` covering the roadmap's
  minimum cross-test set plus 3 constant cross-checks:
  connection preface bytes (byte-identical with the client
  magic per RFC 9113 §3.4), frame type / flag / settings
  parameter constants (3 items — error code constants
  dropped because Nghttp2Wrapper.jl does not export
  `NGHTTP2_NO_ERROR`-style constants; error code wire values
  are covered implicitly by the GOAWAY and RST_STREAM items
  instead), HPACK encode-both-ways via `HpackDeflater` /
  `HpackInflater` (RFC 7541, semantic-equivalent comparison
  on decoded header lists), SETTINGS round-trip (RFC 9113
  §6.5), PING round-trip with 8-byte opaque data (RFC 9113
  §6.7), GOAWAY exercising NO_ERROR / PROTOCOL_ERROR /
  CANCEL across 3 server-initiated last-stream-ids (RFC 9113
  §6.8), DATA frame round-trip + PADDED wire-layout
  validation (RFC 9113 §6.1), WINDOW_UPDATE handshake (RFC
  9113 §6.9), RST_STREAM error-code bit-level encoding (RFC
  9113 §6.4). **105 interop assertions total, all passing.**
  Full-suite count after M4: **24,872** (main 24,767 +
  interop 105).
- `docs/src/nghttp2-parity.md` parity page: table-driven with
  columns Test / Element / RFC / Direction / Verdict / Notes,
  one row per interop item, explicit RFC 9113 / RFC 7541
  citations on every row, `## Known-green versions` section
  naming `nghttp2_jll v1.64.0+1` + `Nghttp2Wrapper.jl
  a3dbdfb5` + `Julia 1.12.6`, `## Deliberate divergences`
  section (empty at M4 — every verdict is either
  byte-identical or semantic-equivalent), `## How to re-run
  the interop group locally` with a copy-paste recipe. Wired
  into `docs/make.jl`'s pages array between the Flow control
  page and the API Reference orientation index.
- New CI job `interop` in `.github/workflows/CI.yml` pinned
  to `ubuntu-latest` + Julia `1` (stable). Not matrixed —
  the `julia = "1.12"` floor of Nghttp2Wrapper.jl precludes
  running it on 1.10. The job clones Nghttp2Wrapper.jl from
  GitHub via `Pkg.add(url=..., rev=...)` to the pinned SHA,
  instantiates the interop env, and runs
  `julia --project=test/interop test/interop/runtests.jl`.
  No `continue-on-error` anywhere — interop failures fail CI.
- Package version bump `0.2.0` → `0.3.0` signalling that M4
  is the first milestone to validate HTTP2.jl's wire
  behaviour against an external reference implementation.
- **Milestone 3 — Stream, Flow Control & Connection migration, flow-control edge cases, public API.**
  Completes the public API surface across all five layers of the
  HTTP/2 stack (frames, HPACK, streams, connection, flow control)
  and retires every M1/M2 carryover shim.
- 21 native `@testitem` units for the stream state machine in
  `test/testitems_stream.jl`, replacing three M1/M2 shims
  (`M0 carryover: http2_stream`, `M0 carryover:
  stream_state_validation`, and the stream-state-machine part of
  `M0 carryover: conformance`). Item names use the `Stream: *`
  prefix — contributors can filter for
  `receive_headers transitions`, `RST_STREAM`, `gRPC header
  helpers`, etc. in isolation.
- 5 native `@testitem` units for the connection lifecycle in
  `test/testitems_connection.jl`, replacing the `M0 carryover:
  connection_management` shim and the preface-processing part of
  the conformance shim. The M0 upstream task labels
  (`T037`–`T041`) are renamed to concern-level names:
  `Connection: preface handshake`, `Connection: PING handling`,
  `Connection: GOAWAY handling`, `Connection: connection-level
  flow control`, `Connection: stream management`.
- **8 newly authored `Flow: *` `@testitem` units** in
  `test/testitems_flow_control.jl` — the first dedicated
  flow-control coverage in HTTP2.jl's history. Upstream
  gRPCServer.jl had no flow-control test file; these 8 items
  were authored from scratch at M3 and cover: window consume and
  release, zero-window edge, 2^31 − 1 overflow protection,
  WINDOW_UPDATE threshold semantics, initial-size delta
  application, stream-vs-connection window interaction,
  SETTINGS-driven initial-window-size change propagation, and
  `DataSender` frame splitting. **All 8 pass on first run — no
  FR-011(c) bug fixes were needed.** 58 new flow-control
  assertions.
- Three new documentation pages: `docs/src/streams.md`,
  `docs/src/connection.md`, `docs/src/flow-control.md`. Each
  has a narrative introduction, a **`## Role signalling`**
  section naming whether the layer is server-only, role-neutral,
  or client-ready, and `@docs` blocks covering every exported
  symbol.
- Three new `jldoctest` examples — one per stateful layer —
  attached to `HTTP2Stream` (state transition round-trip),
  `HTTP2Connection` (preface processing), and
  `FlowControlWindow` (consume + release cycle). All executed by
  Documenter 1.x at build time. Total doctests after M3: **5**
  (2 from M2 + 3 from M3).
- Export block in `src/HTTP2.jl` extended with **79 new symbols**
  across the stream, connection, and flow-control layers. Total
  exports after M3: **119** (up from 40 at M2).
- Role signalling summary table added to `docs/src/api.md` —
  the orientation index now answers "what does HTTP2.jl support
  from a client context today?" at a glance, with a forward
  reference to Milestone 6 for client-role symmetry.
- `upstream-bugs.md` entry **gRPC-specific header helpers live in
  src/stream.jl** recording the layering concern inherited from
  the M0 extraction: `get_grpc_encoding`,
  `get_grpc_accept_encoding`, `get_grpc_timeout`, and
  `get_metadata` are gRPC-layer concepts that conceptually belong
  in a gRPC adapter, not in a pure HTTP/2 library. The entry is
  `open` and points at a future layering-cleanup milestone.
- Package version bump `0.1.0` → `0.2.0` signalling that
  HTTP2.jl now has a complete public API across all five layers.
  No tagged release — Milestone 7 is still the release target.
- **Milestone 2 — Frames & HPACK migration, conformance, public API.**
  HTTP2.jl now has a formal public API surface for the frames and HPACK
  layers. See the `Frames` and `HPACK` pages in the documentation and
  [`specs/003-migrate-frames-hpack/contracts/README.md`](specs/003-migrate-frames-hpack/contracts/README.md)
  for the explicit contract.
- 8 native `@testitem` units for HPACK (`test/testitems_hpack.jl`),
  replacing the opaque M1 `M0 carryover: hpack` shim. Contributors can
  run `huffman`, `integer`, `string`, `dynamic table`, `encoder/decoder`,
  etc. in isolation.
- 13 native `@testitem` units for HTTP/2 frame types
  (`test/testitems_frames.jl`): types/flags/error-code enums, constants,
  connection preface bytes, frame header encode/decode/round-trip, and
  per-type handling of PING, GOAWAY, SETTINGS, WINDOW_UPDATE,
  RST_STREAM.
- 4 `HPACK conformance:` `@testitem` units
  (`test/testitems_hpack_conformance.jl`) cross-validating HTTP2.jl's
  HPACK against the
  [`http2jp/hpack-test-case`](https://github.com/http2jp/hpack-test-case)
  vector set. Extracted under `test/fixtures/hpack-test-case/` (4
  producers × 32 stories = 128 story files). The conformance run
  exercises 13,536 decoder cases across three producers (nghttp2,
  go-hpack, python-hpack) and 3,384 encoder-self-test cases on the
  raw-data producer — **23,688 conformance tests total**, all passing.
- `@testmodule HPACKFixtures` shared test utility providing a hex
  decoder, JSON loader, and producer iteration helpers for the
  hpack-test-case vectors (lives in `test/testitems_hpack_conformance.jl`
  alongside the items that consume it via `setup=[HPACKFixtures]`).
- `docs/src/frames.md` page covering the frame layer public API:
  wire format constants, namespace submodules (FrameType, FrameFlags,
  ErrorCode, SettingsParameter), `FrameHeader`, generic `Frame`, and
  the 11 per-type constructors and parsers.
- `docs/src/hpack.md` page covering the HPACK layer public API:
  `HPACKEncoder`, `HPACKDecoder`, `encode_headers`, `decode_headers`,
  `DynamicTable`, and 7 low-level primitives (Huffman + integer +
  string encode/decode).
- HPACK round-trip `jldoctest` in `src/hpack.jl` attached to
  `HPACKEncoder`'s docstring — constructs an encoder and decoder,
  round-trips a 3-header list, and is executed by Documenter at build
  time. (Constitution Principle V: first milestone with an executable
  doctest.)
- `Frame` round-trip `jldoctest` in `src/frames.jl` attached to the
  `Frame` convenience constructor's docstring — builds a PING frame,
  encodes, decodes, and checks the payload bytes round-trip.
- `export` block in `src/HTTP2.jl` exposing ~40 frame + HPACK symbols
  as the first formal public API surface. See the
  [003-migrate-frames-hpack contract](specs/003-migrate-frames-hpack/contracts/README.md)
  for the full enumerated list.
- `JSON` test-only dependency
  (UUID `682c06a0-de6a-54ab-a142-c8b1cf79cde6`) via `[extras]` +
  `[targets].test`. Does not enter `[deps]` — HTTP2.jl's runtime
  dependency set remains empty, preserving Principle I.
- Package version bump `0.0.1` → `0.1.0` signalling the first
  declared public API surface. No tagged release yet — M7 is the
  release milestone per `ROADMAP.md`.
- Initial import of the HTTP/2 implementation (frames, HPACK, stream state
  machine, connection lifecycle, flow control) from
  [gRPCServer.jl](https://github.com/s-celles/gRPCServer.jl) at commit
  `4abc0932`. See the **Provenance** appendix at the bottom of this file
  for the full per-file table, license-inheritance clause, and the list
  of files deliberately excluded from the extraction.
- Package manifest `Project.toml` declaring HTTP2.jl as a Julia package
  with UUID `7d1e1b98-28e7-4969-8df9-5a308937986a`, version `0.0.1`,
  minimum Julia `1.10`, and an **empty `[deps]` block** — HTTP2.jl has
  zero runtime dependencies and relies only on Julia `Base`. This is
  the first concrete validation of constitution Principle I (Pure Julia
  Implementation).
- Root module `src/HTTP2.jl` that `include`s the five Milestone 0
  source files in dependency order (frames → hpack → stream →
  flow_control → connection). No symbols are exported yet; public-API
  curation is deferred to Milestones 2 and 3.
- TestItemRunner-based test harness: `test/runtests.jl` calling
  `@run_package_tests`, and `test/testitems.jl` defining five
  `@testitem` shims that `include` the Milestone 0 test files. The
  harness satisfies constitution Principle II without migrating the
  carry-over files, which will move to native `@testitem` form in
  Milestones 2 and 3 per the roadmap.
- Documenter skeleton under `docs/`: `docs/Project.toml`, `docs/make.jl`
  (with `warnonly = false`, `checkdocs = :exports`, and a CI-guarded
  `deploydocs` call), `docs/src/index.md` (landing page), and
  `docs/src/api.md` (explicit `@docs` block covering 17 public types
  and namespace submodules). The documentation build is **warning-free**,
  which activates the constitution Principle V gate from this milestone
  onward.
- GitHub Actions CI: `.github/workflows/CI.yml` runs the test matrix
  (Julia `1.10` + stable, ubuntu-latest) on every push and pull
  request, and `.github/workflows/Documentation.yml` runs the
  Documenter build on pushes to `main` and on pull requests.
- `upstream-bugs.md` bootstrap — the canonical place to record bugs
  in HTTP2.jl's upstream dependencies or tooling, per the `CLAUDE.md`
  working rule. Currently empty of entries.

### Changed (Milestone 4)

- **Milestone 4 — test/runtests.jl filters the interop group**.
  `test/runtests.jl` now passes a `filter` kwarg to
  `@run_package_tests` that excludes items whose name starts
  with `Interop: `. This keeps the main suite resolvable on
  Julia 1.10 (where Nghttp2Wrapper.jl cannot be loaded) and
  reserves the interop items for the separate `test/interop/`
  env.
- `docs/make.jl` pages array grows from 7 to 8 entries: Home
  → Frames → HPACK → Streams → Connection → Flow control →
  Interop parity → API Reference.
- **No FR-014 bug fixes applied at Milestone 4**. The interop
  cross-tests surfaced no defects in HTTP2.jl's implementation.
  `src/` is unchanged across all five layer files (frames,
  hpack, stream, flow_control, connection). Initial test
  failures were attributable to test-authoring errors
  (wrong stream-ID parity for a client-session GOAWAY, an
  overly-pessimistic `@test_broken` on DATA padding that
  unexpectedly passed) and were corrected on the test side,
  not in `src/`.
- **Milestone 3 retirement of all remaining shims.** The four
  M1/M2 carryover shims that were still in place at the end of
  M2 (`M0 carryover: http2_stream`, `M0 carryover: conformance
  (stream/preface, pending M3)`, `M0 carryover:
  stream_state_validation`, `M0 carryover: connection_management`)
  are all retired. Their content is fully represented by the
  21 `Stream:` and 5 `Connection:` native test items.
  `test/testitems.jl` (the shim file) is **deleted** — no `M0
  carryover:` items remain in the test discovery list.
- **M3 deletions of the four M0 carryover test files** now that
  their content lives in native `@testitem` files: deleted
  `test/test_http2_stream.jl` (→ `testitems_stream.jl`),
  `test/test_http2_conformance.jl` (→
  `testitems_stream.jl` and `testitems_connection.jl`),
  `test/test_stream_state_validation.jl` (→
  `testitems_stream.jl`), and `test/test_connection_management.jl`
  (→ `testitems_connection.jl`).
- `docs/src/api.md` refactored into a **five-page orientation
  index**. Previous `@docs` blocks that covered stream, connection,
  and flow-control symbols on this page have moved to the
  dedicated layer pages (`streams.md`, `connection.md`,
  `flow-control.md`); `api.md` now contains a one-paragraph
  introduction, a bulleted list linking to all five layer pages,
  and a role-coverage summary table. (FR-015 resolved.)
- `docs/make.jl`'s `pages = [...]` array grew from 4 entries to
  7: Home → Frames → HPACK → Streams → Connection → Flow
  control → API Reference.
- `upstream-bugs.md` lost its `_(none yet)_` placeholder and
  gained its first entry (see the gRPC-helpers bullet under
  `### Added` above).
- `HTTP2Connection` docstring refined to state explicitly that
  it is currently server-role only and that client-role setup
  is scheduled for Milestone 6. `FlowControlWindow` docstring
  refined to cite RFC 9113 §5.2 and note the thread-safety
  guarantee. (FR-011(a) docstring refinements.)
- **Milestone 2 restructuring of the test tree.** Deleted
  `test/test_hpack.jl` (fully migrated to `test/testitems_hpack.jl`).
  Reduced `test/test_http2_conformance.jl` to only its Stream state
  machine and Connection preface processing testsets — the frame-related
  testsets (PING/GOAWAY/SETTINGS/WINDOW_UPDATE/RST_STREAM, frame header
  encode/decode/round-trip, and the type/flags/error-code enums) are
  now `Frames:` `@testitem`s in `test/testitems_frames.jl`. The shim
  for the reduced file in `test/testitems.jl` was retitled
  `M0 carryover: conformance (stream/preface, pending M3)` to signal
  its temporary status. The three other M1 shims (`http2_stream`,
  `stream_state_validation`, `connection_management`) remain in place
  until their own M3 migration.
- **Removed the `M0 carryover: hpack` shim** from `test/testitems.jl`
  now that native coverage replaces it.
- **M2 docstring additions to `src/frames.jl`** (FR-011 permitted):
  added one-line docstrings to the 7 public constants
  `FRAME_HEADER_SIZE`, `DEFAULT_INITIAL_WINDOW_SIZE`,
  `DEFAULT_MAX_FRAME_SIZE`, `MIN_MAX_FRAME_SIZE`, `MAX_MAX_FRAME_SIZE`,
  `DEFAULT_HEADER_TABLE_SIZE`, `CONNECTION_PREFACE`. Each cites the
  relevant RFC section. Required to keep `checkdocs = :exports`
  warning-free after exporting them.
- **M2 docstring extensions** on `HPACKEncoder` (added a usage example
  and `jldoctest` block) and `Frame` (the convenience constructor —
  added a `jldoctest` block). Function bodies unchanged.
- **Resolved M0 Provenance appendix deferral** for
  `test/fixtures/hpack-test-case/`: the fixture set is now extracted
  into `test/fixtures/hpack-test-case/` and exercised by the four
  `HPACK conformance:` test items. See below for the updated exclusion
  entry.
- Deleted dead `include("../fixtures/conformance_data.jl")` +
  `using .ConformanceData` lines (plus the now-orphaned preceding
  comment) from `test/test_http2_conformance.jl` and
  `test/test_connection_management.jl`. The `ConformanceData`
  fixture was deliberately excluded at Milestone 0; zero symbols
  from it were referenced in either test file, so the lines were
  pure dead imports that prevented the test files from loading.
  Permitted by spec `002-package-scaffolding` FR-011 and recorded
  in the plan's data-model entity 8 validation rule V35. The
  cleanup is wider than the plan originally named (lines 7–9
  instead of just line 9) because lines 7 and 8 are the orphaned
  comment and the broken `include` that line 9 was joined to.
- Removed five failing `@testset` blocks from
  `test/test_stream_state_validation.jl` (covering
  `send_grpc_response on closed stream`,
  `send_error_response on closed stream`,
  `send_grpc_response on non-existent stream`,
  `send_error_response on non-existent stream`, and
  `get_response_content_type helper`). These testsets referenced
  gRPC-layer helper functions (`send_grpc_response`,
  `send_error_response`, `get_response_content_type`) that live
  outside the upstream `http2/` submodule and were never in scope
  for HTTP2.jl. The remaining five testsets in the same file
  continue to test legitimate HTTP/2 state machine behavior
  (`can_send`, `can_send_on_stream`, `StreamError`, `RST_STREAM`,
  and `END_STREAM` handling) and all pass. Permitted by spec
  `002-package-scaffolding` FR-011; this is a Milestone 0 scoping
  error corrected at Milestone 1, not a regression against
  upstream. **1021 tests pass, 0 fail, 0 error.**

### Notes on plan deviations (Milestone 4)

- The plan's `test/Project.toml` file was not created. Test
  dependencies are instead declared via `[extras]` + `[targets]` in
  the top-level `Project.toml`, which is the modern Julia convention
  (Julia 1.2+) and eliminates a redundant manifest file. Both
  approaches work with `Pkg.test()`; the chosen approach is simpler.
- Research R7/R9 did not identify `checkdocs = :exports` as the
  simplest escape from Documenter 1.x's `:missing_docs` check. The
  implementation discovered it during T021 when a naked `warnonly =
  false` build failed on 60+ M0 docstrings. `checkdocs = :exports`
  plus zero exports at M1 makes the check pass trivially without
  downgrading any warning category.
- The plan's `@docs` list for `docs/src/api.md` grew from 11 to 17
  entries during T021 because Documenter additionally flagged six
  namespace submodules (`FrameType`, `FrameFlags`, `ErrorCode`,
  `SettingsParameter`, `StreamState`, `ConnectionState`) that are
  part of the public surface per their use in the test files. All
  had existing docstrings in the M0 code, so adding them to the
  `@docs` block was a no-code change.
- The TestItemRunner scanner did **not** duplicate-evaluate the
  Milestone 0 test files (research R4's residual risk). The
  conditional fallback (move files to `test/_m0_carryover/`) was
  not needed; the five `@testitem` shims in `test/testitems.jl`
  produced exactly five item results.

---

## Provenance

> This appendix is not part of the Keep-a-Changelog-formatted entries
> above; it is the provenance record for the initial lift-and-shift that
> created HTTP2.jl. It is kept here (rather than in a separate `NOTICE`
> file) so the record lives alongside the changelog entry it
> substantiates.

HTTP2.jl began as a lift-and-shift extraction of the `http2` submodule of
gRPCServer.jl. The production sources and their matching unit tests were
copied verbatim into this repository; the only modifications applied
during extraction were (a) rewriting the file-level header comment of
each source file to identify HTTP2.jl as its current home, and (b) in
test files only, rewriting `using gRPCServer` → `using HTTP2` and the
word-bounded identifier prefix `gRPCServer.` → `HTTP2.`. No other edits
were made. See `specs/001-extract-http2-module/research.md` (R3, R4, R8)
for the evidence supporting that this was a safe textual substitution.

### Upstream origin

- **Repository**: <https://github.com/s-celles/gRPCServer.jl>
- **Branch**: `develop`
- **Commit**: `4abc09324736b3597da5502385dbce24a1edb174`
- **Commit message**: `feat: add gRPCClient.jl integration tests`

### Extracted files

Production sources (5 files, copied to `src/`):

| Upstream path | Target path | LOC |
|---|---|---|
| `src/http2/frames.jl` | `src/frames.jl` | 547 |
| `src/http2/hpack.jl` | `src/hpack.jl` | 963 |
| `src/http2/stream.jl` | `src/stream.jl` | 462 |
| `src/http2/flow_control.jl` | `src/flow_control.jl` | 440 |
| `src/http2/connection.jl` | `src/connection.jl` | 717 |

Unit tests (5 files, copied to `test/`):

| Upstream path | Target path | LOC |
|---|---|---|
| `test/unit/test_hpack.jl` | `test/test_hpack.jl` | 378 |
| `test/unit/test_http2_stream.jl` | `test/test_http2_stream.jl` | 488 |
| `test/unit/test_http2_conformance.jl` | `test/test_http2_conformance.jl` | 427 |
| `test/unit/test_stream_state_validation.jl` | `test/test_stream_state_validation.jl` | 218 |
| `test/unit/test_connection_management.jl` | `test/test_connection_management.jl` | 244 |

Total: 10 files, ~4884 lines of code.

### License inheritance

gRPCServer.jl is distributed under the MIT License. HTTP2.jl is also
distributed under the MIT License, with copyright held by Sébastien
Celles (see the top-level `LICENSE` file). Because both the upstream
project and HTTP2.jl share the same author and the same license, the
extracted code retains its original copyright and license unchanged: no
re-licensing occurred and none was required.

Any contributor who subsequently modifies the extracted files in
HTTP2.jl does so under the MIT License in force in this repository
(see `./LICENSE`).

### Exclusions — files deliberately NOT extracted at Milestone 0

The following files exist in the upstream project alongside the ten
files above but were intentionally left behind. Each exclusion is
recorded here per spec FR-010 so future maintainers can tell the
difference between "forgotten" and "deliberately excluded".

- **`test/TestUtils.jl`** — gRPC integration harness that builds a raw
  TCP/HTTP2 mock client scoped to the upstream gRPC test suite. Not
  used by any of the five HTTP/2 unit test files extracted here. Not
  planned for re-extraction; if HTTP2.jl ever needs a test helper of
  its own it will be written from scratch under the constitution's TDD
  rule.
- **`test/fixtures/hpack-test-case/`** — HPACK conformance vectors
  (go-hpack, nghttp2, python-hpack, raw-data). Not referenced by
  `test_hpack.jl` as currently extracted — the upstream
  Huffman/integer/string tests are hand-rolled. Deferred to Milestone 2
  (Frames & HPACK), which will pull in the vector set as part of the
  HPACK conformance push.
  **→ Resolved at Milestone 2**: extracted into
  `test/fixtures/hpack-test-case/` and exercised by the four
  `HPACK conformance:` test items (23,688 conformance tests total).
- **`src/http2/*.cov`** — Julia code-coverage artifacts (e.g.
  `hpack.jl.1286406.cov`) left over from upstream test runs. Build
  outputs, not source. Excluded by allow-listed copy; will never be
  extracted.
- **`test/unit/test_streams.jl`** — gRPC-layer stream wrapper tests
  (`ServerStream`, `ClientStream`, `BidiStream`). Exercises
  abstractions built on top of the HTTP/2 state machine, not the state
  machine itself. The HTTP/2 state-machine coverage lives entirely in
  `test_http2_stream.jl` and `test_stream_state_validation.jl`, both of
  which were extracted.

### Verification

The extraction and its post-conditions are verified by the step-by-step
walkthrough in `specs/001-extract-http2-module/quickstart.md`. In
particular:

- `rg -n '\bgRPCServer\b' src/ test/` — MUST return zero matches
- `find src/ test/ -name '*.cov' -print` — MUST return zero lines
- `head -n 1 src/*.jl` — every first line MUST end with `HTTP2.jl`

These checks were run at extraction time and passed; re-running them
from a fresh clone will reproduce the same results.
