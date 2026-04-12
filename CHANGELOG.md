# Changelog

All notable changes to HTTP2.jl will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and HTTP2.jl adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

### Changed

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

### Notes on plan deviations

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
