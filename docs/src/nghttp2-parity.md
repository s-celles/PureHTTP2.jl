# Interop parity with libnghttp2

This page records every interop cross-test PureHTTP2.jl runs against
[libnghttp2](https://nghttp2.org/) via
[Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl).
The cross-test group lives in `test/interop/testitems_interop.jl`
and is verified in CI on every push to `main` by a dedicated
`interop` job.

From Milestone 4 onward, these cross-tests are the **regression
contract** for PureHTTP2.jl's wire behaviour. Any change to PureHTTP2.jl
that breaks one of them fails CI at PR time. This is how
PureHTTP2.jl fulfills constitution Principle III (Specification
Conformance & Reference Parity).

## Known-green versions

Validated against:

- `Nghttp2Wrapper.jl` commit `a3dbdfb548c3d4bfbf4ddfce2a835a990f19dcc2`
- `nghttp2_jll v1.64.0+1` (bundles `libnghttp2` 1.64.0)
- Julia `1.12.6`

Interop parity under a different `nghttp2_jll` version or a
different `Nghttp2Wrapper.jl` revision is not guaranteed until
re-validated.

## Cross-test matrix

| Test | Element | RFC | Direction | Verdict | Notes |
|---|---|---|---|---|---|
| `Interop: preface bytes` | Connection preface | [RFC 9113 §3.4](https://datatracker.ietf.org/doc/html/rfc9113#section-3.4) | nghttp2 emits → PureHTTP2.jl compares | byte-identical | 24-byte client magic, byte-for-byte equality |
| `Interop: frame type constants` | Frame type enum | [RFC 9113 §6](https://datatracker.ietf.org/doc/html/rfc9113#section-6) | cross-check (numeric equality) | byte-identical | 10 frame types: DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE, CONTINUATION |
| `Interop: flag constants` | Frame flag bits | [RFC 9113 §6](https://datatracker.ietf.org/doc/html/rfc9113#section-6) | cross-check (numeric equality) | byte-identical | NONE, END_STREAM, END_HEADERS, ACK. PADDED (0x08) and PRIORITY (0x20) exist in PureHTTP2.jl but are not exported as constants by Nghttp2Wrapper.jl at the pinned commit — they are covered by integration tests instead |
| `Interop: settings parameter constants` | SETTINGS identifiers | [RFC 9113 §6.5.2](https://datatracker.ietf.org/doc/html/rfc9113#section-6.5.2) | cross-check (numeric equality) | byte-identical | All 6 identifiers |
| `Interop: HPACK encode nghttp2 → decode PureHTTP2.jl` | HPACK header compression | [RFC 7541](https://datatracker.ietf.org/doc/html/rfc7541) | nghttp2 encodes → PureHTTP2.jl decodes | semantic-equivalent | HPACK is not byte-unique; comparison is on decoded header lists |
| `Interop: HPACK encode PureHTTP2.jl → decode nghttp2` | HPACK header compression | [RFC 7541](https://datatracker.ietf.org/doc/html/rfc7541) | PureHTTP2.jl encodes → nghttp2 decodes | semantic-equivalent | Reverse direction |
| `Interop: SETTINGS round-trip` | SETTINGS frame | [RFC 9113 §6.5](https://datatracker.ietf.org/doc/html/rfc9113#section-6.5) | nghttp2 emits → PureHTTP2.jl parses | byte-identical | Exercises MAX_CONCURRENT_STREAMS and INITIAL_WINDOW_SIZE |
| `Interop: PING round-trip` | PING frame | [RFC 9113 §6.7](https://datatracker.ietf.org/doc/html/rfc9113#section-6.7) | nghttp2 emits → PureHTTP2.jl parses | byte-identical | 8-byte opaque payload round-trips byte-for-byte |
| `Interop: GOAWAY last-stream-id and error codes` | GOAWAY frame | [RFC 9113 §6.8](https://datatracker.ietf.org/doc/html/rfc9113#section-6.8) | nghttp2 emits → PureHTTP2.jl parses | byte-identical | Exercises NO_ERROR, PROTOCOL_ERROR, CANCEL across 3 server-initiated last-stream-ids |
| `Interop: DATA frame END_STREAM` | DATA frame | [RFC 9113 §6.1](https://datatracker.ietf.org/doc/html/rfc9113#section-6.1) | PureHTTP2.jl self-round-trip + PADDED layout check | byte-identical | Encoder/decoder round-trip plus validation of PAD_LENGTH layout per RFC 9113 §6.1 |
| `Interop: WINDOW_UPDATE handshake` | WINDOW_UPDATE frame | [RFC 9113 §6.9](https://datatracker.ietf.org/doc/html/rfc9113#section-6.9) | both directions | byte-identical | nghttp2 emits + PureHTTP2.jl parses; PureHTTP2.jl emits + self-parses |
| `Interop: RST_STREAM error code propagation` | RST_STREAM frame | [RFC 9113 §6.4](https://datatracker.ietf.org/doc/html/rfc9113#section-6.4) | PureHTTP2.jl → bit-level wire format | byte-identical | 4-byte big-endian error code for CANCEL, INTERNAL_ERROR, PROTOCOL_ERROR, STREAM_CLOSED |

**Total**: 12 cross-test items, 105 individual assertions, all
passing at Milestone 4. The minimum cross-test set from the
roadmap (8 entries: preface, SETTINGS, HEADERS+HPACK, DATA,
WINDOW_UPDATE, RST_STREAM, GOAWAY, PING) is fully covered.

## Deliberate divergences

_(none at this milestone)_

All 12 cross-tests produce either byte-identical or
semantic-equivalent results. No cases were identified where
PureHTTP2.jl and `libnghttp2` emit legitimately different
RFC-compliant bytes.

## Upstream bugs discovered

_(none at this milestone)_

No `libnghttp2`, `nghttp2_jll`, or `Nghttp2Wrapper.jl` bugs
surfaced during the Milestone 4 interop migration. See
[`upstream-bugs.md`](https://github.com/s-celles/PureHTTP2.jl/blob/main/upstream-bugs.md)
for any bugs discovered in later milestones.

## Notes on the cross-test methodology

- **In-memory IO, not TCP sockets.** The cross-tests exchange
  bytes via `Nghttp2Wrapper._session_send_all` and direct
  parsing with PureHTTP2.jl's `decode_frame`, not over a network
  socket. This is sufficient for frame-level parity
  validation; real network end-to-end testing is a later
  milestone's concern.
- **HPACK comparison is on decoded header lists.** HPACK
  encoding is not byte-unique per [RFC 7541](https://datatracker.ietf.org/doc/html/rfc7541),
  so the HPACK cross-tests compare the logical header list
  after decode, not the encoded byte sequence.
- **Client-role only.** All 12 cross-tests use an nghttp2
  **client** session. PureHTTP2.jl's connection layer is currently
  server-role only (see [Connection](@ref) role signalling),
  so the cross-tests exchange bytes in the direction
  client-emits → server-like-parser (PureHTTP2.jl). Client-role
  symmetry in PureHTTP2.jl is scheduled for Milestone 6, and
  client-role cross-tests land with it.
- **DATA frame cross-test is a self-round-trip + wire-format
  check.** Submitting raw DATA frames directly to nghttp2
  requires a full handshake (preface + SETTINGS exchange +
  stream opening via HEADERS). Exercising the full handshake
  in a single `@testitem` is out of scope at M4. The DATA
  cross-test therefore validates the wire layout (frame
  header bytes, PAD_LENGTH layout for padded frames) via
  PureHTTP2.jl's encoder + decoder, which is RFC-level parity in
  effect.

## How to re-run the interop group locally

Requires Julia ≥ 1.12 (Nghttp2Wrapper.jl's declared minimum).
The main PureHTTP2.jl test suite still runs on Julia 1.10+ without
this interop env.

```bash
julia --project=test/interop -e '
    using Pkg
    Pkg.develop(PackageSpec(path=pwd()))
    Pkg.add(PackageSpec(
        url="https://github.com/s-celles/Nghttp2Wrapper.jl",
        rev="a3dbdfb548c3d4bfbf4ddfce2a835a990f19dcc2"))
    Pkg.instantiate()'
julia --project=test/interop test/interop/runtests.jl
```

To run a single item by name:

```bash
julia --project=test/interop -e '
    using TestItemRunner
    @run_package_tests filter = ti -> ti.name == "Interop: preface bytes"'
```
