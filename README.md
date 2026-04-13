# PureHTTP2.jl

**Pure-Julia HTTP/2 library** — [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html)
and [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html), covering
both server and client roles, cross-tested against `libnghttp2` via
[Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl).

[![CI](https://github.com/s-celles/PureHTTP2.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/s-celles/PureHTTP2.jl/actions/workflows/CI.yml)
[![Docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://s-celles.github.io/PureHTTP2.jl/stable/)
[![Docs: dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://s-celles.github.io/PureHTTP2.jl/dev/)
[![Version](https://img.shields.io/github/v/tag/s-celles/PureHTTP2.jl)](https://github.com/s-celles/PureHTTP2.jl/releases)
[![License](https://img.shields.io/github/license/s-celles/PureHTTP2.jl)](LICENSE)

## About

PureHTTP2.jl is a standalone implementation of HTTP/2 written entirely in
Julia. It was extracted from the `http2` submodule of
[gRPCServer.jl](https://github.com/s-celles/gRPCServer.jl) and
developed as a reusable library under the
[PureHTTP2.jl constitution](.specify/memory/constitution.md): pure Julia
only, TDD with [TestItemRunner.jl](https://github.com/julia-vscode/TestItemRunner.jl),
reference parity with `libnghttp2`, Keep a Changelog + Semantic
Versioning, and warning-free [Documenter.jl](https://github.com/JuliaDocs/Documenter.jl)
builds.

`[deps]` in `Project.toml` is empty: PureHTTP2.jl has **zero runtime
dependencies** beyond Julia's standard library. Optional TLS / ALPN
support is provided via a package extension that loads when
[OpenSSL.jl](https://github.com/JuliaWeb/OpenSSL.jl) is present in
the same environment.

## Installation

```julia
using Pkg
Pkg.add("PureHTTP2")
```

Minimum Julia version: **1.10**. The `test/interop/` cross-test
environment against Nghttp2Wrapper.jl requires Julia ≥ 1.12
separately.

## A minimal example — h2c client

```julia
using PureHTTP2, Sockets

# Connect to a local h2c server (e.g., Nghttp2Wrapper.HTTP2Server).
tcp = connect(IPv4("127.0.0.1"), 8080)

conn = HTTP2Connection()
result = PureHTTP2.open_connection!(conn, tcp;
    request_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8080"),
    ])

println("status  = ", result.status)
println("headers = ", result.headers)
println("body    = ", String(result.body))

close(tcp)
```

For the server-side counterpart, see
[`docs/src/tls.md`](docs/src/tls.md) and `PureHTTP2.serve_connection!`.
For TLS / ALPN support via the optional OpenSSL extension, see
[`docs/src/client.md`](docs/src/client.md).

## What's supported

- **Frame layer** — encode / decode for all RFC 9113 §6 frame
  types (DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS,
  PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE, CONTINUATION).
- **HPACK** — encoder / decoder with dynamic table and Huffman
  compression, cross-validated against 23,688 conformance cases
  from [http2jp/hpack-test-case](https://github.com/http2jp/hpack-test-case).
- **Stream state machine** — RFC 9113 §5 transitions with odd /
  even stream-ID parity enforcement.
- **Connection lifecycle** — preface exchange, SETTINGS
  negotiation, flow control, GOAWAY, graceful shutdown.
- **Server-role IO entry point** — `serve_connection!(conn, io)`
  drives a server over any `Base.IO` satisfying the IO adapter
  contract (`read(io, n::Int)`, `write(io, bytes)`, `close(io)`).
- **Client-role IO entry point** — `open_connection!(conn, io;
  request_headers, request_body)` drives a single client-role
  request / response exchange over the same contract.
- **Optional TLS ALPN helper** — `PureHTTP2.set_alpn_h2!(ctx)`
  provided by the `PureHTTP2OpenSSLExt` package extension when
  OpenSSL.jl is loaded. Converts a `Vector{String}` protocol
  list into RFC 7301 §3.1 wire format and hands it to
  OpenSSL's `ssl_set_alpn`.
- **Reference parity against `libnghttp2`** — 14 `Interop:`
  `@testitem` units in `test/interop/` cross-test PureHTTP2.jl
  against Nghttp2Wrapper.jl, including a live h2c TCP round
  trip in each direction (server-role and client-role).
- **Documentation** — 10-page [Documenter.jl](https://github.com/JuliaDocs/Documenter.jl)
  site with warning-free builds enforced from Milestone 1
  onward.

## Current limitations

At `v0.1.0`, the following are deliberately **not yet** shipped:

- **Server-side h2 TLS ALPN** — blocked on an upstream OpenSSL.jl
  binding gap for `SSL_CTX_set_alpn_select_cb`. The client-side
  ALPN helper (`set_alpn_h2!`) works end-to-end; the server side
  cannot yet negotiate `h2` in a TLS handshake. Tracked in
  [`upstream-bugs.md`](upstream-bugs.md).
- **Multi-request client sessions** — `open_connection!` ships a
  single-request API. Stream multiplexing and long-lived sessions
  over one connection are a post-`v0.1.0` concern.
- **Affirmative server push handling** — `open_connection!` and
  `serve_connection!` negotiate `SETTINGS_ENABLE_PUSH = 0` and
  treat any `PUSH_PROMISE` as a connection-level `PROTOCOL_ERROR`
  per RFC 9113 §8.4. Accepting, processing, or explicitly
  refusing pushed streams is out of scope.
- **Multi-frame request bodies** — `request_body` is a single
  `Vector{UInt8}` written as one DATA frame. Chunked / streamed
  uploads are deferred.
- **macOS / Windows CI** — the CI matrix is Linux-only at
  `v0.1.0`. PureHTTP2.jl is pure Julia and should work on other
  platforms, but it is not yet tested there.
- **Stream priority beyond best-effort** (RFC 9113 §5.3),
  extensible SETTINGS per RFC 7540 §6.5.2, performance
  benchmarks, and a fuzz harness — all deferred to post-`v0.1.0`
  milestones. See [`ROADMAP.md`](ROADMAP.md).

## Links

- **Documentation** (stable): <https://s-celles.github.io/PureHTTP2.jl/stable/>
- **Documentation** (dev): <https://s-celles.github.io/PureHTTP2.jl/dev/>
- **Changelog**: [`CHANGELOG.md`](CHANGELOG.md)
- **Roadmap**: [`ROADMAP.md`](ROADMAP.md)
- **Reference parity vs `libnghttp2`**: [`docs/src/nghttp2-parity.md`](docs/src/nghttp2-parity.md)
- **Upstream bug tracker**: [`upstream-bugs.md`](upstream-bugs.md)

## License

PureHTTP2.jl is distributed under the [MIT License](LICENSE). See the
Provenance appendix in [`CHANGELOG.md`](CHANGELOG.md) for the
extraction history and license inheritance from gRPCServer.jl.

## Acknowledgements

PureHTTP2.jl was lifted and shifted from the `http2` submodule of
[gRPCServer.jl](https://github.com/s-celles/gRPCServer.jl) at
commit [`4abc0932`](https://github.com/s-celles/gRPCServer.jl/tree/4abc09324736b3597da5502385dbce24a1edb174).
Reference parity is validated against the C implementation
[`libnghttp2`](https://nghttp2.org/) via
[Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl).
