# TLS & transport

HTTP/2 runs over two flavours of transport: **h2** (TLS-wrapped, the
default on the public internet per RFC 9113 §3.3) and **h2c** (HTTP/2
over cleartext TCP, RFC 9113 §3.4). At Milestone 5, HTTP2.jl is
server-role only and delivers **h2c** end-to-end over any Julia
`Base.IO` transport. Client-role code and live server-side TLS ALPN
are out of scope at M5 — see the limitations section at the bottom
of this page.

## h2c vs h2

| Protocol | Transport            | Negotiation                | HTTP2.jl status |
| -------- | -------------------- | -------------------------- | --------------- |
| `h2c`    | cleartext TCP        | Known at connect time (RFC 9113 §3.4, client magic `PRI * HTTP/2.0`) | ✅ fully supported at M5 via [`serve_connection!`](@ref) |
| `h2`     | TLS ≥ 1.2            | TLS ALPN (RFC 7301)        | ⚠️ client-side ALPN helper scaffolded, server-side deferred (see below) |

`h2c` is the natural fit for gRPC over private networks, CI harnesses,
and cross-tests against reference implementations like `nghttp2`.
`h2` is required by browsers.

## IO adapter contract

`serve_connection!` drives an [`HTTP2Connection`](@ref) through any
`Base.IO` value that implements three methods:

| Method | Semantics |
| ------ | --------- |
| `read(io, n::Int) :: Vector{UInt8}` | Read up to `n` bytes. May return fewer than `n` **only** on EOF — a partial return followed by EOF is treated as a graceful close and the read loop exits. |
| `write(io, bytes)`                  | Write all bytes. Standard `Base.write` contract. |
| `close(io)`                         | Terminate the transport. The caller of `serve_connection!` is responsible for closing `io` once the function returns. |

`eof(io)` is optional. If your transport type supports it, the loop
will still work; if it does not, the `read` short-return is the EOF
signal.

The contract deliberately does **not** require thread safety,
backpressure, timeouts, or `isopen(io)` — these are added by the
caller when needed. See `specs/006-tls-alpn-support/contracts/README.md`
in the repository for the formal contract and the list of PR-gated
"how to break it" rules.

### Transports known to satisfy the contract

| Transport            | Use case                               |
| -------------------- | -------------------------------------- |
| `Base.IOBuffer`      | In-memory unit tests (needs a split-IO wrapper for bidirectional use) |
| `Base.BufferStream`  | Paired in-memory pipes (testing blocking reads) |
| `Base.Pipe`          | Process-boundary I/O                   |
| `Sockets.TCPSocket`  | Real h2c over loopback or production TCP |
| `OpenSSL.SSLStream`  | Forward-compat with h2 (not live-tested at M5) |

```@docs
HTTP2.serve_connection!
```

## Driving HTTP2.jl over a raw socket

The canonical h2c server loop on real TCP:

```julia
using HTTP2, Sockets

server = listen(IPv4(0x7f000001), 8080)  # 127.0.0.1:8080
while isopen(server)
    sock = accept(server)
    @async begin
        conn = HTTP2Connection()
        try
            serve_connection!(conn, sock)
        catch err
            @warn "h2c connection terminated" exception=err
        finally
            close(sock)
        end
    end
end
```

This loop has been cross-tested at M5 against the `libnghttp2`
reference implementation via Nghttp2Wrapper.jl — see the
[`Interop: h2c live TCP handshake`](nghttp2-parity.md) test item in
`test/interop/testitems_interop.jl`.

## Optional OpenSSL.jl extension

HTTP2.jl does **not** depend on OpenSSL.jl at runtime. Its `[deps]`
block is empty by design (constitution Principle I). When
`using OpenSSL` is in scope alongside `using HTTP2`, Julia's
package-extension mechanism activates `HTTP2OpenSSLExt`, which adds
one method to the generic [`set_alpn_h2!`](@ref) function:

```julia
using HTTP2, OpenSSL

ctx = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
HTTP2.set_alpn_h2!(ctx)                   # register "h2"
HTTP2.set_alpn_h2!(ctx, ["h2", "http/1.1"])  # with fallback
```

Under the hood the helper converts the `Vector{String}` into the
RFC 7301 §3.1 wire format (length-prefixed concatenation, max 255
bytes per protocol) and calls OpenSSL.jl's `ssl_set_alpn`, which
wraps `SSL_CTX_set_alpn_protos`. Names longer than 255 bytes are
rejected with `ArgumentError` before any ccall.

```@docs
HTTP2.set_alpn_h2!
```

When OpenSSL.jl is **not** in the environment, `HTTP2.set_alpn_h2!`
still exists as a generic function with zero methods. Calling it
throws `MethodError` — by design. HTTP2.jl's runtime dependency
graph stays empty and the package extension is an opt-in feature
activated only by environments that bring their own OpenSSL.

## Current limitations

**Server-side ALPN for `h2` is not yet supported.** OpenSSL.jl at
the M5 target version does not export
`SSL_CTX_set_alpn_select_cb`, the server-side selection callback
required to negotiate `h2` in a TLS handshake initiated by a client.
HTTP2.jl has an open upstream entry for this in `upstream-bugs.md`
at the repository root. Once the binding lands, HTTP2.jl gains a
matching helper and a live `h2` cross-test.

**Client-role HTTP2.jl code** is deferred to Milestone 6. The
`set_alpn_h2!` helper shipped at M5 is a forward-compatible
scaffold — it exercises the extension pattern and the wire-format
conversion today, and gains a live TLS cross-test once the client
role lands.

**`h2c` is fully supported.** If your deployment is inside a
trusted network, behind a TLS-terminating proxy, or a gRPC service
running over loopback, the `serve_connection!` + TCP pattern above
is the intended shipping path at M5.
