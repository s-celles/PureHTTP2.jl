# API Reference

PureHTTP2.jl's public API is organised into five layers. Each layer
has a dedicated documentation page with docstrings and examples
for every exported symbol.

- [Frames](@ref) — wire format, frame header, per-type
  constructors, namespace submodules for frame types, flags,
  settings parameters, and error codes.
- [HPACK](@ref) — encoder/decoder, dynamic table, low-level
  primitives. Cross-validated against the
  [http2jp/hpack-test-case](https://github.com/http2jp/hpack-test-case)
  vector set in CI.
- [Streams](@ref) — stream state machine, state transitions,
  header accessors.
- [Connection](@ref) — connection lifecycle, preface handshake,
  frame dispatch.
- [Flow control](@ref) — sliding windows, multi-stream
  controller, high-level senders and receivers.

## Role coverage

PureHTTP2.jl's current public API is primarily **server-role**:

| Layer | Role |
|---|---|
| Frames | Role-neutral |
| HPACK | Role-neutral |
| Streams | Mostly role-neutral (header accessors assume server-role reading request headers) |
| Connection | **Currently server-role only** |
| Flow control | Role-neutral |

Client-role symmetry — specifically, sending the connection
preface, processing a server's SETTINGS frame, and exercising the
outbound APIs from a client context — is scheduled for
**Milestone 6**. See [ROADMAP.md](https://github.com/s-celles/PureHTTP2.jl/blob/main/ROADMAP.md).
