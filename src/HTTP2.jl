module HTTP2

include("frames.jl")
include("hpack.jl")
include("stream.jl")
include("flow_control.jl")
include("connection.jl")
include("serve.jl")

"""
    set_alpn_h2!(ctx, protocols=["h2"])

Register the HTTP/2 ALPN protocol identifier on a TLS context.

This is a generic function whose methods are provided by the
`HTTP2OpenSSLExt` package extension. The extension loads automatically
via `Base.get_extension` when [`OpenSSL.jl`](https://github.com/JuliaWeb/OpenSSL.jl)
is present in the same environment as HTTP2.jl.

**Without OpenSSL.jl loaded**, this function has zero methods and
calling it throws `MethodError` — by design. HTTP2.jl's runtime
dependency graph stays empty (constitution Principle I); OpenSSL
is a *weak* dependency activated only when you `using OpenSSL`.

**With OpenSSL.jl loaded**, a method for `OpenSSL.SSLContext`
becomes available:

```julia
using HTTP2, OpenSSL
ctx = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
HTTP2.set_alpn_h2!(ctx)              # register "h2"
HTTP2.set_alpn_h2!(ctx, ["h2", "http/1.1"])  # register with fallback
```

The method converts the user-facing `Vector{String}` into the
RFC 7301 §3.1 wire format (length-prefixed concatenation) before
handing off to OpenSSL.

# Current limitations

At Milestone 5, HTTP2.jl is **server-role only** and OpenSSL.jl does
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

end # module HTTP2
