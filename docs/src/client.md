# Client

Milestone 6 delivers PureHTTP2.jl's client-role entry point:
[`open_connection!`](@ref). It is the symmetric counterpart to
[`serve_connection!`](@ref) from Milestone 5 and reuses the exact
same IO adapter contract, so any transport that works on the
server side (IOBuffer wrappers, BufferStream pairs, TCP sockets,
`OpenSSL.SSLStream`) also works for the client.

## Client vs server

HTTP/2 is a symmetric wire protocol but the two peers play
**different roles** at negotiation time. The client sends a
24-byte connection preface, the server does not; the client
opens streams with odd IDs, the server uses even IDs for
server-initiated push; the client typically sets
`SETTINGS_ENABLE_PUSH = 0` to opt out of server push, while the
server advertises its own initial SETTINGS. PureHTTP2.jl reflects
this asymmetry with two entry points:

| Role   | Entry point            | Delivered in |
| ------ | ---------------------- | ------------ |
| Server | `serve_connection!`    | Milestone 5  |
| Client | `open_connection!`     | Milestone 6  |

Both functions take an `HTTP2Connection` + an `IO` and drive a
frame read/write loop, but they differ in **what they write on
startup** (preface + initial SETTINGS on the client side; nothing
until the peer's preface arrives on the server side) and in
**how they classify incoming HEADERS frames** (request HEADERS
on the server, response HEADERS on the client).

## Driving PureHTTP2.jl as a client

### Over cleartext TCP (h2c)

The simplest deployment is h2c over loopback or a trusted
network. PureHTTP2.jl's client pump takes a raw `Sockets.TCPSocket`
and handles everything else:

```julia
using PureHTTP2, Sockets

tcp = connect(IPv4("127.0.0.1"), 8080)
conn = HTTP2Connection()
result = PureHTTP2.open_connection!(conn, tcp;
    request_headers = Tuple{String, String}[
        (":method", "GET"),
        (":path", "/"),
        (":scheme", "http"),
        (":authority", "127.0.0.1:8080"),
    ])

println("status = ", result.status)
println("headers = ", result.headers)
println("body = ", String(result.body))
close(tcp)
```

This pattern has been cross-tested against the reference
`libnghttp2` implementation (via Nghttp2Wrapper.jl) in the
`Interop: h2c live TCP client` item at
`test/interop/testitems_interop.jl`.

### Over TLS (h2) via `PureHTTP2OpenSSLExt`

For h2 over TLS, wrap the TCP socket in an `OpenSSL.SSLStream`
after configuring ALPN via the [`set_alpn_h2!`](@ref) helper
provided by the [`PureHTTP2OpenSSLExt`](tls.md) package extension:

```julia
using PureHTTP2, OpenSSL, Sockets

ctx = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
PureHTTP2.set_alpn_h2!(ctx)  # advertise "h2" to the server

tcp = connect(IPv4("127.0.0.1"), 8443)
tls = OpenSSL.SSLStream(ctx, tcp)
OpenSSL.connect(tls)

conn = HTTP2Connection()
result = PureHTTP2.open_connection!(conn, tls;
    request_headers = Tuple{String, String}[
        (":method", "GET"),
        (":path", "/"),
        (":scheme", "https"),
        (":authority", "127.0.0.1:8443"),
    ])

close(tls)
```

The TLS setup — context construction, ALPN registration,
handshake — is the caller's responsibility. PureHTTP2.jl takes
any `::IO`, which keeps its runtime dependency graph empty
(constitution Principle I preserved).

### Over TLS (h2) via `PureHTTP2ReseauExt`

Milestone 7.5 adds a second TLS backend:
[Reseau.jl](https://github.com/JuliaServices/Reseau.jl). Reseau
binds `SSL_CTX_set_alpn_select_cb` (the server-side ALPN
selection callback that OpenSSL.jl does not yet expose), so if
you need server-side h2 over TLS, Reseau is the recommended
backend. Client-side h2 works through Reseau too — the
`PureHTTP2ReseauExt` extension ships a one-shot helper:

```julia
using PureHTTP2, Reseau

# reseau_h2_connect calls Reseau.TLS.connect(address; ...)
# with alpn_protocols=["h2"] merged in and returns a
# fully-handshaken Reseau.TLS.Conn (which satisfies PureHTTP2.jl's
# IO adapter contract natively — no wrapper needed).
client = PureHTTP2.reseau_h2_connect("tcp", "127.0.0.1:8443";
    server_name = "127.0.0.1",
    verify_peer = false)  # self-signed fixture; omit for prod

conn = HTTP2Connection()
result = PureHTTP2.open_connection!(conn, client;
    request_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/"),
        (":scheme",    "https"),
        (":authority", "127.0.0.1:8443"),
    ])

close(client)
```

Both the `PureHTTP2OpenSSLExt` path (above) and the `PureHTTP2ReseauExt`
path coexist — neither displaces the other. See
[TLS & transport](tls.md) for the full comparison of the two
backends, docstrings for all three `reseau_h2_*` helpers, and
the constructor-vs-mutator symmetry-break between them.

## The `open_connection!` contract

```@docs
PureHTTP2.open_connection!
```

## Receiving responses

`open_connection!` returns a `NamedTuple{(:status, :headers, :body)}`:

- `status`: the integer parsed from the `:status` pseudo-header
  of the response HEADERS frame.
- `headers`: the full response header list as
  `Vector{Tuple{String, String}}`, including `:status` as the
  first entry.
- `body`: the concatenated payload of all DATA frames received
  on the response stream, as `Vector{UInt8}`. Empty if the
  response carried `END_STREAM` on the HEADERS frame (a common
  pattern for 204 No Content or empty bodies).

The order of entries in `headers` is preserved as sent by the
server, so callers looking for `"content-type"` or similar can
scan the list with `findfirst` or a straightforward loop.

## Error handling

### Graceful GOAWAY

A GOAWAY with `NO_ERROR` received **after** the response is
complete causes `open_connection!` to return normally. A GOAWAY
received **before** the response is complete raises a
[`ConnectionError`](@ref) with code `NO_ERROR` and a message
indicating the peer closed mid-exchange. Both behaviors are
covered in the `Client: receive GOAWAY (NO_ERROR)` test item.

### RST_STREAM on the response stream

If the server sends a RST_STREAM frame targeting the client's
stream, `open_connection!` raises a [`StreamError`](@ref) with
the server-provided error code. The caller can inspect
`err.stream_id` and `err.error_code` to diagnose. See the
`Client: receive RST_STREAM` test item.

### Connection-level protocol errors

GOAWAY with any non-`NO_ERROR` code, PUSH_PROMISE received
while `ENABLE_PUSH = 0` is negotiated (RFC 9113 §8.4), frame
sizes exceeding `max_frame_size` (RFC 9113 §6.5.2), and
malformed frames all raise [`ConnectionError`](@ref) with the
corresponding error code. The `Client: receive GOAWAY
(PROTOCOL_ERROR)`, `Client: reject PUSH_PROMISE when ENABLE_PUSH=0`,
and `Client: frame size exceeding max_frame_size` items guard
these paths.

## Current limitations

Several capabilities are deliberately **not** shipped at M6
and are expected at Milestone 7+:

- **Single-request API**: `open_connection!` sends exactly one
  request and collects exactly one response. Multi-request
  pipelining over a persistent connection, stream multiplexing,
  and long-lived client sessions are deferred.
- **No affirmative server push handling**: the client
  negotiates `SETTINGS_ENABLE_PUSH = 0` and treats any
  `PUSH_PROMISE` as a protocol error. Push handling (whether to
  accept, process, or explicitly refuse pushed streams with
  `RST_STREAM(REFUSED_STREAM)`) is out of scope.
- **Multi-frame request bodies**: `request_body` is a single
  `Vector{UInt8}` written as one DATA frame. Chunked uploads,
  streamed request bodies, and bodies larger than the negotiated
  `SETTINGS_MAX_FRAME_SIZE` are deferred.
- **Server-side TLS ALPN**: still blocked on OpenSSL.jl upstream.
  `set_alpn_h2!` is live-tested at M6 on the **client side** of
  a TLS handshake, but the `h2` protocol is not actually
  selected by Nghttp2Wrapper.jl's server because
  `SSL_CTX_set_alpn_select_cb` is not yet bound. See
  `upstream-bugs.md` at the repository root for the full chain.
  PureHTTP2.jl itself does not serve h2 over TLS at M6.
- **URL parsing / HTTP semantics**: the caller provides pseudo-
  headers directly. PureHTTP2.jl is a transport layer, not an HTTP
  client. Redirects, cookies, authentication, and content
  negotiation are application-layer concerns.

## See also

- [TLS & transport](tls.md) — the shared IO adapter contract
  and the optional OpenSSL package extension used by both
  `serve_connection!` and `open_connection!`.
- [Interop parity](nghttp2-parity.md) — live cross-tests against
  `libnghttp2` via Nghttp2Wrapper.jl, including the `Interop: h2c
  live TCP client` item added at M6.
