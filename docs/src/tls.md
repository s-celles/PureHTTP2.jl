# TLS & transport

HTTP/2 runs over two flavours of transport: **h2** (TLS-wrapped, the
default on the public internet per RFC 9113 §3.3) and **h2c** (HTTP/2
over cleartext TCP, RFC 9113 §3.4). At Milestone 5, PureHTTP2.jl is
server-role only and delivers **h2c** end-to-end over any Julia
`Base.IO` transport. Client-role code and live server-side TLS ALPN
are out of scope at M5 — see the limitations section at the bottom
of this page.

## h2c vs h2

| Protocol | Transport            | Negotiation                | PureHTTP2.jl status |
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
PureHTTP2.serve_connection!
```

## Driving PureHTTP2.jl over a raw socket

The canonical h2c server loop on real TCP:

```julia
using PureHTTP2, Sockets

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

## TLS backends

PureHTTP2.jl does **not** depend on any TLS library at runtime. Its
`[deps]` block is empty by design (constitution Principle I).
Instead, PureHTTP2.jl ships two **optional** TLS backends as Julia
package extensions. You opt into whichever one your environment
already uses; PureHTTP2.jl itself is agnostic and accepts any
`Base.IO` satisfying the IO adapter contract.

| Backend | Extension module | Client ALPN | Server ALPN | Use when |
| ------- | ---------------- | ----------- | ----------- | -------- |
| [OpenSSL.jl](https://github.com/JuliaWeb/OpenSSL.jl) | `PureHTTP2OpenSSLExt` | ✅ via `set_alpn_h2!` | ❌ blocked on upstream binding | You're already depending on OpenSSL.jl or want a mutable `SSLContext` you can configure piecemeal. |
| [Reseau.jl](https://github.com/JuliaServices/Reseau.jl) | `PureHTTP2ReseauExt` | ✅ via `reseau_h2_client_config` / `reseau_h2_connect` | ✅ via `reseau_h2_server_config` | You need **server-side h2 over TLS** today, or you already depend on Reseau.jl for other reasons. |

Both extensions coexist — loading both packages activates both
sets of helpers simultaneously. There are no method collisions:
the two backends use different generic function names
(`set_alpn_h2!` for OpenSSL, `reseau_h2_*` for Reseau).

### OpenSSL.jl

When `using OpenSSL` is in scope alongside `using PureHTTP2`, Julia's
package-extension mechanism activates `PureHTTP2OpenSSLExt`, which
adds one method to the generic [`set_alpn_h2!`](@ref) function:

```julia
using PureHTTP2, OpenSSL

ctx = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
PureHTTP2.set_alpn_h2!(ctx)                    # register "h2"
PureHTTP2.set_alpn_h2!(ctx, ["h2", "http/1.1"])  # with fallback
```

Under the hood the helper converts the `Vector{String}` into the
RFC 7301 §3.1 wire format (length-prefixed concatenation, max 255
bytes per protocol) and calls OpenSSL.jl's `ssl_set_alpn`, which
wraps `SSL_CTX_set_alpn_protos`. Names longer than 255 bytes are
rejected with `ArgumentError` before any ccall.

```@docs
PureHTTP2.set_alpn_h2!
```

**OpenSSL.jl caveat**: `set_alpn_h2!` is **client-side only** at
Milestone 7.5 because OpenSSL.jl does not yet bind
`SSL_CTX_set_alpn_select_cb`, the server-side selection callback
required to negotiate `h2` in a handshake initiated by a client.
PureHTTP2.jl's `upstream-bugs.md` entry for this gap is marked
`worked-around via Reseau.jl` (see the Reseau backend below) —
users who specifically want the OpenSSL-only code path still need
the upstream binding to land.

### Reseau.jl

When `using Reseau` is in scope alongside `using PureHTTP2`, the
`PureHTTP2ReseauExt` extension activates and adds three
**constructor-style** helpers:

```julia
using PureHTTP2, Reseau

# Server side: hand to Reseau.TLS.listen
server_cfg = PureHTTP2.reseau_h2_server_config(;
    cert_file = "server.crt",
    key_file  = "server.key",
)

listener = Reseau.TLS.listen("tcp", "0.0.0.0:443", server_cfg)
conn = Reseau.TLS.accept(listener)
Reseau.TLS.handshake!(conn)
# Reseau.TLS.connection_state(conn).alpn_protocol is now "h2"
PureHTTP2.serve_connection!(PureHTTP2.HTTP2Connection(), conn)
```

```julia
using PureHTTP2, Reseau

# Client side: one-shot h2-over-TLS connect
client = PureHTTP2.reseau_h2_connect("tcp", "example.com:443";
    server_name = "example.com")

conn = HTTP2Connection()
result = PureHTTP2.open_connection!(conn, client;
    request_headers = Tuple{String,String}[
        (":method",    "GET"),
        (":path",      "/"),
        (":scheme",    "https"),
        (":authority", "example.com"),
    ])
close(client)
```

```@docs
PureHTTP2.reseau_h2_server_config
PureHTTP2.reseau_h2_client_config
PureHTTP2.reseau_h2_connect
PureHTTP2.ALPN_H2_PROTOCOLS
```

Reseau.jl binds `SSL_CTX_set_alpn_select_cb` internally (at
`src/5_tls.jl:725-732` in Reseau v1.0.1), which is the exact
upstream gap that blocks server-side h2 on OpenSSL.jl. This
makes Reseau the **recommended backend for server-side h2 TLS**
until OpenSSL.jl adds its own binding.

**Symmetry-break**: the Reseau helpers are **constructors**, not
mutators. `Reseau.TLS.Config` is an immutable Julia struct
(`alpn_protocols` is defensively `copy()`-ed at construction in
Reseau v1.0.1 `src/5_tls.jl:240`), so an analogous
`set_alpn_h2!(::Reseau.TLS.Config)` is structurally impossible.
The `reseau_h2_*` helpers build fresh configs with
`alpn_protocols = PureHTTP2.ALPN_H2_PROTOCOLS` pre-populated; callers
override via an explicit `alpn_protocols=...` kwarg.

### Extension-absent behavior

When **neither** OpenSSL.jl nor Reseau.jl is in the environment,
all four helpers exist as generic functions with **zero** methods.
Calling them throws `MethodError` — by design. PureHTTP2.jl's runtime
dependency graph stays empty and the extensions are opt-in.

## Current limitations

**`h2c` is fully supported.** If your deployment is inside a
trusted network, behind a TLS-terminating proxy, or a gRPC
service running over loopback, the `serve_connection!` +
`Sockets.TCPSocket` pattern above is the intended shipping path.

**Server-side `h2` over TLS is supported via Reseau.jl** — see
the "Reseau.jl" subsection above. An analogous server-side helper
in `PureHTTP2OpenSSLExt` awaits OpenSSL.jl's
`SSL_CTX_set_alpn_select_cb` binding landing upstream. The
upstream tracking entry in `upstream-bugs.md` is marked
`worked-around via Reseau.jl`.

**Client-role PureHTTP2.jl code** shipped at Milestone 6. Both
backends' helpers work with [`open_connection!`](@ref) on the
client side.
