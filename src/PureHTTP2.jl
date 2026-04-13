module PureHTTP2

include("frames.jl")
include("hpack.jl")
include("stream.jl")
include("flow_control.jl")
include("connection.jl")
include("serve.jl")
include("client.jl")

"""
    set_alpn_h2!(ctx, protocols=["h2"])

Register the HTTP/2 ALPN protocol identifier on a TLS context.

This is a generic function whose methods are provided by the
`PureHTTP2OpenSSLExt` package extension. The extension loads automatically
via `Base.get_extension` when [`OpenSSL.jl`](https://github.com/JuliaWeb/OpenSSL.jl)
is present in the same environment as PureHTTP2.jl.

**Without OpenSSL.jl loaded**, this function has zero methods and
calling it throws `MethodError` — by design. PureHTTP2.jl's runtime
dependency graph stays empty (constitution Principle I); OpenSSL
is a *weak* dependency activated only when you `using OpenSSL`.

**With OpenSSL.jl loaded**, a method for `OpenSSL.SSLContext`
becomes available:

```julia
using PureHTTP2, OpenSSL
ctx = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
PureHTTP2.set_alpn_h2!(ctx)              # register "h2"
PureHTTP2.set_alpn_h2!(ctx, ["h2", "http/1.1"])  # register with fallback
```

The method converts the user-facing `Vector{String}` into the
RFC 7301 §3.1 wire format (length-prefixed concatenation) before
handing off to OpenSSL.

# Current limitations

At Milestone 5, PureHTTP2.jl is **server-role only** and OpenSSL.jl does
not yet export `SSL_CTX_set_alpn_select_cb` (the server-side selection
callback). `set_alpn_h2!` is therefore scaffolded for forward
compatibility with Milestone 6's client-role work and is not yet
live-tested end-to-end against a real TLS peer. See
`docs/src/tls.md` for the full story and `upstream-bugs.md` for
the upstream tracking entry.
"""
function set_alpn_h2! end

# Public API (Milestone 2): frames layer
export FrameType, FrameFlags, ErrorCode, SettingsParameter
export FrameHeader, Frame
export encode_frame, decode_frame
export encode_frame_header, decode_frame_header, has_flag
export data_frame, headers_frame, settings_frame, parse_settings_frame
export ping_frame, goaway_frame, parse_goaway_frame
export rst_stream_frame, window_update_frame, parse_window_update_frame
export continuation_frame
export FRAME_HEADER_SIZE, CONNECTION_PREFACE
export DEFAULT_INITIAL_WINDOW_SIZE, DEFAULT_MAX_FRAME_SIZE
export MIN_MAX_FRAME_SIZE, MAX_MAX_FRAME_SIZE, DEFAULT_HEADER_TABLE_SIZE

# Public API (Milestone 2): HPACK layer
export DynamicTable, HPACKEncoder, HPACKDecoder
export encode_headers, decode_headers
export set_max_table_size!, encode_table_size_update
export huffman_encode, huffman_decode, huffman_encoded_length
export encode_integer, decode_integer
export encode_string, decode_string

# Public API (Milestone 3): stream layer
export HTTP2Stream, StreamError, StreamState
export is_client_initiated, is_server_initiated
export can_send, can_receive, is_closed
export receive_headers!, send_headers!
export receive_data!, send_data!
export receive_rst_stream!, send_rst_stream!
export update_send_window!, update_recv_window!
export get_data, peek_data
export get_header, get_headers
export get_method, get_path, get_authority, get_content_type
export get_grpc_encoding, get_grpc_accept_encoding, get_grpc_timeout, get_metadata

# Public API (Milestone 3): flow control layer
export FlowControlWindow, FlowController
export consume!, try_consume!, release!, available
export should_send_update, get_update_increment, update_initial_size!
export create_stream_window!, get_stream_window, remove_stream_window!
export consume_send!, max_sendable
export apply_window_update!, apply_settings_initial_window_size!, generate_window_updates
export DataSender, send_data_frames, DataReceiver

# Public API (Milestone 3): connection layer
export HTTP2Connection, ConnectionError, ConnectionSettings, ConnectionState
export apply_settings!, to_frame
export get_stream, can_send_on_stream, create_stream, remove_stream, active_stream_count
export process_preface, process_frame
export process_settings_frame!, process_ping_frame!, process_goaway_frame!
export process_window_update_frame!, process_headers_frame!, process_continuation_frame!
export process_data_frame!, process_rst_stream_frame!
export send_headers, send_data, send_trailers, send_rst_stream, send_goaway
export is_open

# Public API (Milestone 5): transport layer
export serve_connection!, set_alpn_h2!

# Public API (Milestone 6): client layer
export open_connection!

"""
    PureHTTP2.ALPN_H2_PROTOCOLS :: Vector{String}

The canonical ALPN protocol list for HTTP/2 (`["h2"]`, per
[RFC 7301 §3.1](https://www.rfc-editor.org/rfc/rfc7301#section-3.1)
and [RFC 9113 §3.3](https://www.rfc-editor.org/rfc/rfc9113#section-3.3)).
Reusable by any TLS backend — PureHTTP2.jl ships two optional TLS
backend extensions that both consume this list:

- `PureHTTP2OpenSSLExt` uses it as the default in
  [`set_alpn_h2!(::OpenSSL.SSLContext)`](@ref set_alpn_h2!) when
  the caller passes no explicit list.
- `PureHTTP2ReseauExt` uses it as the default in the `reseau_h2_*`
  constructor helpers
  ([`reseau_h2_server_config`](@ref), [`reseau_h2_client_config`](@ref),
  [`reseau_h2_connect`](@ref)) when the caller passes no
  explicit list.

Callers should treat this constant as read-only; callers who want
a different list pass one explicitly via the `alpn_protocols`
keyword argument.
"""
const ALPN_H2_PROTOCOLS = String["h2"]

"""
    PureHTTP2.reseau_h2_server_config(; cert_file, key_file, kwargs...) -> Reseau.TLS.Config

Build a [Reseau.jl](https://github.com/JuliaServices/Reseau.jl)
server-side TLS config with `alpn_protocols=["h2"]` pre-populated.
Requires `cert_file::AbstractString` and `key_file::AbstractString`
as keyword arguments; forwards every other keyword argument to
`Reseau.TLS.Config`. If the caller passes an explicit
`alpn_protocols=` kwarg, that value overrides the default
[`ALPN_H2_PROTOCOLS`](@ref).

This generic function is a **stub** in the main module — a method
for `Reseau.TLS.Config` is provided by the `PureHTTP2ReseauExt` package
extension, which loads automatically when Reseau.jl is in the
environment. Without Reseau loaded, calling this function throws
`MethodError`.

# Example

```julia
using PureHTTP2, Reseau

cfg = PureHTTP2.reseau_h2_server_config(;
    cert_file = "server.crt",
    key_file  = "server.key",
)

listener = Reseau.TLS.listen("tcp", "0.0.0.0:443", cfg)
conn = Reseau.TLS.accept(listener)
Reseau.TLS.handshake!(conn)
# At this point Reseau.TLS.connection_state(conn).alpn_protocol
# is "h2" (client advertised it) or nothing (client did not).
PureHTTP2.serve_connection!(PureHTTP2.HTTP2Connection(), conn)
```

# Why not `set_alpn_h2!`?

Milestone 5 shipped `PureHTTP2.set_alpn_h2!(ctx::OpenSSL.SSLContext)`
as a **mutator** on a mutable C-backed context. `Reseau.TLS.Config`
is an immutable Julia struct whose `alpn_protocols` field is
defensively copied at construction, so an analogous mutator is
structurally impossible. The `reseau_h2_*` helpers are
**constructor-style** instead. See
`specs/009-reseau-tls-backend/contracts/README.md` Section 2 for
the full symmetry-break rationale.
"""
function reseau_h2_server_config end

"""
    PureHTTP2.reseau_h2_client_config(; kwargs...) -> Reseau.TLS.Config

Build a [Reseau.jl](https://github.com/JuliaServices/Reseau.jl)
client-side TLS config with `alpn_protocols=["h2"]` pre-populated.
Thin convenience wrapper around `Reseau.TLS.Config` — forwards all
keyword arguments. If the caller passes an explicit
`alpn_protocols=` kwarg, that value overrides the default
[`ALPN_H2_PROTOCOLS`](@ref).

This generic function is a **stub** in the main module — a method
for the Reseau config type is provided by the `PureHTTP2ReseauExt`
package extension, which loads automatically when Reseau.jl is in
the environment. Without Reseau loaded, calling this function
throws `MethodError`.

See also: [`reseau_h2_server_config`](@ref),
[`reseau_h2_connect`](@ref), [`ALPN_H2_PROTOCOLS`](@ref).
"""
function reseau_h2_client_config end

"""
    PureHTTP2.reseau_h2_connect(address::AbstractString; kwargs...) -> Reseau.TLS.Conn

One-shot client helper: calls `Reseau.TLS.connect(address; ...)`
with `alpn_protocols=["h2"]` merged into the keyword arguments.
Returns a fully-handshaken `Reseau.TLS.Conn` ready to hand to
[`open_connection!`](@ref).

If the caller passes an explicit `alpn_protocols=` kwarg, that
value overrides the default [`ALPN_H2_PROTOCOLS`](@ref). Other
Reseau.jl connect keywords such as `server_name`,
`verify_peer`, and `handshake_timeout_ns` are forwarded
unchanged.

This generic function is a **stub** in the main module — a method
is provided by the `PureHTTP2ReseauExt` package extension, which loads
automatically when Reseau.jl is in the environment. Without
Reseau loaded, calling this function throws `MethodError`.

# Example

```julia
using PureHTTP2, Reseau

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
"""
function reseau_h2_connect end

# Public API (Milestone 7.5): Reseau TLS backend helpers
export ALPN_H2_PROTOCOLS
export reseau_h2_server_config, reseau_h2_client_config, reseau_h2_connect

end # module PureHTTP2
