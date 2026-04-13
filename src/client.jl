# Milestone 6: client-role transport layer.
#
# `open_connection!` drives a client-role HTTP/2 connection over any
# `Base.IO` transport satisfying the IO adapter contract documented
# in `specs/006-tls-alpn-support/contracts/README.md` (inherited
# verbatim at M6 — see `specs/007-client-role-completion/contracts/README.md`).
#
# Symmetric to M5's server-role `serve_connection!`. Sends the
# 24-byte client connection preface + SETTINGS + the request
# HEADERS/DATA, then drives a frame read loop until the response is
# complete, returning a `NamedTuple{(:status, :headers, :body), ...}`.
#
# The client-role frame handlers in this file **do not** call the
# server-role `process_*_frame!` helpers in `src/connection.jl` —
# those embed server-side assumptions (stream-ID parity checks,
# `last_client_stream_id` enforcement) that are wrong for a client
# receiving a response. The client pump uses a parallel dispatch
# that reuses the shared pure functions (`decode_frame_header`,
# `decode_headers`, `parse_settings_frame`, `parse_goaway_frame`,
# `encode_frame`, `apply_settings!`).

"""
    ClientStreamState(stream_id::UInt32)

Private mutable struct tracking an in-flight client-opened stream
and the response being assembled on it.

Fields:

- `stream_id`: the odd stream ID this client opened.
- `response_headers`: list of `(name, value)` pairs accumulated from
  HEADERS (and CONTINUATION reassembly).
- `response_body`: `IOBuffer` growing with each DATA frame payload.
- `headers_complete`: `true` once a HEADERS or CONTINUATION frame
  with `END_HEADERS` has been processed.
- `end_stream_received`: `true` once any frame on this stream has
  `END_STREAM` set.
- `continuation_accumulator`: raw header block fragment bytes held
  while waiting for `END_HEADERS` across split HEADERS frames.
"""
mutable struct ClientStreamState
    stream_id::UInt32
    response_headers::Vector{Tuple{String, String}}
    response_body::IOBuffer
    headers_complete::Bool
    end_stream_received::Bool
    continuation_accumulator::Vector{UInt8}
end

ClientStreamState(stream_id::UInt32) = ClientStreamState(
    stream_id, Tuple{String, String}[], IOBuffer(), false, false, UInt8[])

# ---- Write helpers --------------------------------------------------------

function _write_preface_and_settings!(conn::HTTP2Connection, io::IO)
    write(io, CONNECTION_PREFACE)
    # Client declares ENABLE_PUSH=0 so the server cannot send
    # PUSH_PROMISE frames. M6 does not handle affirmative push.
    settings = Tuple{UInt16, UInt32}[
        (SettingsParameter.ENABLE_PUSH, UInt32(0)),
    ]
    write(io, encode_frame(settings_frame(settings)))
    return nothing
end

function _write_request!(conn::HTTP2Connection, io::IO,
                         request_headers::Vector{Tuple{String, String}},
                         request_body::Union{Vector{UInt8}, Nothing})
    stream_id = conn.next_stream_id
    conn.next_stream_id += UInt32(2)  # next odd after this one

    has_body = request_body !== nothing
    header_block = encode_headers(conn.hpack_encoder, request_headers)

    headers_flags = FrameFlags.END_HEADERS
    if !has_body
        headers_flags |= FrameFlags.END_STREAM
    end

    headers_frame_obj = Frame(FrameType.HEADERS, headers_flags, stream_id, header_block)
    write(io, encode_frame(headers_frame_obj))

    if has_body
        data_frame_obj = Frame(FrameType.DATA, FrameFlags.END_STREAM,
                               stream_id, request_body)
        write(io, encode_frame(data_frame_obj))
    end

    return stream_id
end

function _read_one_frame(io::IO, max_frame_size::Int)
    header_bytes = read(io, FRAME_HEADER_SIZE)
    if length(header_bytes) < FRAME_HEADER_SIZE
        return nothing  # EOF
    end
    header = decode_frame_header(header_bytes)
    if header.length > max_frame_size
        throw(ConnectionError(ErrorCode.FRAME_SIZE_ERROR,
            "Frame size $(header.length) exceeds max $(max_frame_size)"))
    end
    payload = header.length == 0 ? UInt8[] : read(io, Int(header.length))
    if length(payload) < header.length
        throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
            "Truncated frame payload: got $(length(payload)) of $(header.length) bytes"))
    end
    return Frame(header, payload)
end

# ---- Frame processors (client role) --------------------------------------

function _strip_padding_and_priority(header::FrameHeader,
                                     payload::Vector{UInt8},
                                     allow_priority::Bool)
    data = payload
    if has_flag(header, FrameFlags.PADDED)
        if isempty(data)
            throw(ConnectionError(ErrorCode.PROTOCOL_ERROR, "Empty padded frame"))
        end
        pad_length = data[1]
        if pad_length >= header.length
            throw(ConnectionError(ErrorCode.PROTOCOL_ERROR, "Padding too large"))
        end
        data = data[2:(end - pad_length)]
    end
    if allow_priority && has_flag(header, FrameFlags.PRIORITY_FLAG)
        if length(data) < 5
            throw(ConnectionError(ErrorCode.FRAME_SIZE_ERROR,
                "PRIORITY data too short"))
        end
        data = data[6:end]
    end
    return data
end

function client_process_settings!(conn::HTTP2Connection, io::IO, frame::Frame)
    if has_flag(frame.header, FrameFlags.ACK)
        conn.pending_settings_ack = false
        return nothing
    end
    params = parse_settings_frame(frame)
    apply_settings!(conn.remote_settings, params)
    # Acknowledge the server SETTINGS.
    write(io, encode_frame(settings_frame(; ack=true)))
    return nothing
end

function client_process_headers!(conn::HTTP2Connection,
                                 pending::Dict{UInt32, ClientStreamState},
                                 frame::Frame)
    stream_id = frame.header.stream_id
    if stream_id == 0
        throw(ConnectionError(ErrorCode.PROTOCOL_ERROR, "HEADERS on stream 0"))
    end

    state = get(pending, stream_id, nothing)
    if state === nothing
        # Server-initiated stream on a client? Client hasn't opened this
        # stream (even stream IDs are server-initiated for push). Since
        # we negotiated ENABLE_PUSH=0, this is a protocol violation.
        throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
            "HEADERS on unknown stream $stream_id"))
    end

    header_payload = _strip_padding_and_priority(frame.header, frame.payload, true)
    end_headers = has_flag(frame.header, FrameFlags.END_HEADERS)
    end_stream = has_flag(frame.header, FrameFlags.END_STREAM)

    if end_headers
        combined = if isempty(state.continuation_accumulator)
            header_payload
        else
            vcat(state.continuation_accumulator, header_payload)
        end
        headers = decode_headers(conn.hpack_decoder, combined)
        append!(state.response_headers, headers)
        state.headers_complete = true
        empty!(state.continuation_accumulator)
    else
        append!(state.continuation_accumulator, header_payload)
    end

    if end_stream
        state.end_stream_received = true
    end
    return nothing
end

function client_process_continuation!(conn::HTTP2Connection,
                                      pending::Dict{UInt32, ClientStreamState},
                                      frame::Frame)
    stream_id = frame.header.stream_id
    state = get(pending, stream_id, nothing)
    if state === nothing
        throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
            "CONTINUATION on unknown stream $stream_id"))
    end
    end_headers = has_flag(frame.header, FrameFlags.END_HEADERS)
    if end_headers
        combined = vcat(state.continuation_accumulator, frame.payload)
        headers = decode_headers(conn.hpack_decoder, combined)
        append!(state.response_headers, headers)
        state.headers_complete = true
        empty!(state.continuation_accumulator)
    else
        append!(state.continuation_accumulator, frame.payload)
    end
    return nothing
end

function client_process_data!(conn::HTTP2Connection,
                              pending::Dict{UInt32, ClientStreamState},
                              frame::Frame)
    stream_id = frame.header.stream_id
    state = get(pending, stream_id, nothing)
    if state === nothing
        throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
            "DATA on unknown stream $stream_id"))
    end
    data_payload = _strip_padding_and_priority(frame.header, frame.payload, false)
    write(state.response_body, data_payload)
    if has_flag(frame.header, FrameFlags.END_STREAM)
        state.end_stream_received = true
    end
    return nothing
end

function client_process_rst_stream!(pending::Dict{UInt32, ClientStreamState},
                                    frame::Frame)
    if length(frame.payload) != 4
        throw(ConnectionError(ErrorCode.FRAME_SIZE_ERROR,
            "RST_STREAM payload must be 4 bytes"))
    end
    err_code = (UInt32(frame.payload[1]) << 24) |
               (UInt32(frame.payload[2]) << 16) |
               (UInt32(frame.payload[3]) << 8) |
               UInt32(frame.payload[4])
    throw(StreamError(frame.header.stream_id, err_code,
        "RST_STREAM from peer (code=$err_code)"))
end

function client_process_goaway!(conn::HTTP2Connection, frame::Frame)
    last_stream_id, error_code, _debug = parse_goaway_frame(frame)
    conn.goaway_received = true
    if error_code == ErrorCode.NO_ERROR
        conn.state = ConnectionState.CLOSING
        return true  # signal clean loop exit
    else
        conn.state = ConnectionState.CLOSED
        throw(ConnectionError(error_code,
            "GOAWAY from peer (code=$error_code, last_stream_id=$last_stream_id)"))
    end
end

function client_process_window_update!(conn::HTTP2Connection, frame::Frame)
    # M6's single-request API does not track per-stream flow windows
    # for outbound flow; WINDOW_UPDATE is accepted and ignored.
    return nothing
end

function client_process_ping!(conn::HTTP2Connection, io::IO, frame::Frame)
    if !has_flag(frame.header, FrameFlags.ACK)
        write(io, encode_frame(ping_frame(frame.payload; ack=true)))
    end
    return nothing
end

function client_process_push_promise!(conn::HTTP2Connection, frame::Frame)
    throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
        "Received PUSH_PROMISE despite ENABLE_PUSH=0 (RFC 9113 §8.4)"))
end

function client_dispatch_frame!(conn::HTTP2Connection, io::IO,
                                pending::Dict{UInt32, ClientStreamState},
                                frame::Frame)
    ft = frame.header.frame_type
    if ft == FrameType.SETTINGS
        client_process_settings!(conn, io, frame)
    elseif ft == FrameType.HEADERS
        client_process_headers!(conn, pending, frame)
    elseif ft == FrameType.CONTINUATION
        client_process_continuation!(conn, pending, frame)
    elseif ft == FrameType.DATA
        client_process_data!(conn, pending, frame)
    elseif ft == FrameType.RST_STREAM
        client_process_rst_stream!(pending, frame)
    elseif ft == FrameType.GOAWAY
        return client_process_goaway!(conn, frame)
    elseif ft == FrameType.WINDOW_UPDATE
        client_process_window_update!(conn, frame)
    elseif ft == FrameType.PING
        client_process_ping!(conn, io, frame)
    elseif ft == FrameType.PUSH_PROMISE
        client_process_push_promise!(conn, frame)
    else
        # RFC 9113 §4.1: unknown frame types MUST be ignored.
    end
    return false
end

# ---- Public entry point --------------------------------------------------

"""
    open_connection!(conn::HTTP2Connection, io::IO;
                     request_headers::Vector{Tuple{String, String}},
                     request_body::Union{Vector{UInt8}, Nothing} = nothing,
                     max_frame_size::Int = DEFAULT_MAX_FRAME_SIZE,
                     read_timeout::Union{Nothing, Real} = nothing) ->
        NamedTuple{(:status, :headers, :body), Tuple{Int, Vector{Tuple{String, String}}, Vector{UInt8}}}

Drive a client-role HTTP/2 connection over an arbitrary `Base.IO`
transport and perform one request/response exchange.

This is PureHTTP2.jl's primary client-side entry point. It is the
symmetric counterpart to [`serve_connection!`](@ref) and reuses the
same IO adapter contract (`read(io, n::Int)`, `write(io, bytes)`,
`close(io)`).

The function:

1. Switches `conn` into client role (sets `state = OPEN`,
   `next_stream_id = 1`). Pass a freshly-constructed
   [`HTTP2Connection`](@ref).
2. Writes the 24-byte connection preface followed by an initial
   SETTINGS frame declaring `SETTINGS_ENABLE_PUSH = 0` (affirmative
   server push is not supported at M6).
3. Writes a HEADERS frame carrying `request_headers` on a newly
   allocated odd stream ID. Sets `END_HEADERS` always, and
   `END_STREAM` iff `request_body === nothing`.
4. If `request_body !== nothing`, writes one DATA frame with
   `END_STREAM`.
5. Enters a frame read loop: reads a 9-byte frame header via
   [`decode_frame_header`](@ref), enforces
   `header.length ≤ max_frame_size` (else throws
   [`ConnectionError`](@ref) with `FRAME_SIZE_ERROR`), reads the
   payload, and dispatches to a client-role handler.
6. Accumulates response headers and body into a local
   `ClientStreamState` (not exposed publicly).
7. Exits cleanly when the response stream receives `END_STREAM`,
   on graceful GOAWAY (`NO_ERROR`), or on transport EOF after the
   response is complete.

The caller owns `io` and is responsible for closing it after this
function returns.

# Arguments

- `conn::HTTP2Connection`: freshly-constructed connection. Switched
  to client role as the first step.
- `io::IO`: any `Base.IO` satisfying the IO adapter contract. See
  `docs/src/tls.md` for the contract details.
- `request_headers::Vector{Tuple{String, String}}`: pseudo-headers
  (`:method`, `:path`, `:scheme`, `:authority`) MUST appear first
  per RFC 9113 §8.1.2.1. The function does not validate the
  list — the caller is responsible.
- `request_body`: optional request body bytes. `nothing` sends
  HEADERS with `END_STREAM` and no DATA. M6 ships single-frame
  DATA only; multi-frame bodies are deferred.
- `max_frame_size::Int`: incoming-frame payload size ceiling, in
  bytes. Defaults to [`DEFAULT_MAX_FRAME_SIZE`](@ref) (16 KiB).
- `read_timeout`: reserved for a future milestone. Must be
  `nothing` at M6.

# Returns

A `NamedTuple{(:status, :headers, :body), Tuple{Int, Vector{Tuple{String, String}}, Vector{UInt8}}}` where:

- `status` is the integer parsed from the `:status` pseudo-header.
- `headers` includes **all** response headers in order, including
  `:status` as the first entry.
- `body` is the concatenated payload of all DATA frames received
  on the response stream (empty if the response had `END_STREAM`
  on HEADERS).

# Throws

- [`ConnectionError`](@ref) on connection-level protocol
  violations: truncated frames, `FRAME_SIZE_ERROR`, unexpected
  `PUSH_PROMISE`, GOAWAY with a non-`NO_ERROR` code, EOF before
  the response is complete.
- [`StreamError`](@ref) on a `RST_STREAM` frame targeting the
  response stream.

# Example

```julia
using PureHTTP2, Sockets

tcp = connect(Sockets.IPv4("127.0.0.1"), 8080)
conn = HTTP2Connection()
result = PureHTTP2.open_connection!(conn, tcp;
    request_headers = [
        (":method", "GET"),
        (":path", "/"),
        (":scheme", "http"),
        (":authority", "127.0.0.1:8080"),
    ])
println("status = ", result.status)
println("body   = ", String(result.body))
close(tcp)
```

For TLS / `h2` negotiation via the optional OpenSSL extension,
see [`set_alpn_h2!`](@ref) and `docs/src/client.md`.
"""
function open_connection!(conn::HTTP2Connection, io::IO;
                          request_headers::Vector{Tuple{String, String}},
                          request_body::Union{Vector{UInt8}, Nothing} = nothing,
                          max_frame_size::Int = DEFAULT_MAX_FRAME_SIZE,
                          read_timeout::Union{Nothing, Real} = nothing)
    if read_timeout !== nothing
        throw(ArgumentError("read_timeout is reserved for a future milestone"))
    end

    # Switch to client role. The connection was constructed with
    # server-role defaults (state=PREFACE, next_stream_id=2 for even
    # server-initiated streams); flip both in place so the server-
    # role state machine does not interfere.
    conn.state = ConnectionState.OPEN
    conn.next_stream_id = UInt32(1)
    conn.pending_settings_ack = true

    _write_preface_and_settings!(conn, io)
    stream_id = _write_request!(conn, io, request_headers, request_body)

    pending = Dict{UInt32, ClientStreamState}()
    pending[stream_id] = ClientStreamState(stream_id)

    while !is_closed(conn)
        state = pending[stream_id]
        if state.headers_complete && state.end_stream_received
            break
        end

        frame = _read_one_frame(io, max_frame_size)
        if frame === nothing
            # EOF
            if state.headers_complete && state.end_stream_received
                break
            else
                throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
                    "Transport EOF before response complete"))
            end
        end

        exit_loop = client_dispatch_frame!(conn, io, pending, frame)
        if exit_loop
            # GOAWAY with NO_ERROR: peer signalled graceful shutdown.
            # If the response is already in hand, return it; otherwise
            # report the shutdown as a connection error.
            st = pending[stream_id]
            if st.headers_complete && st.end_stream_received
                break
            else
                throw(ConnectionError(ErrorCode.NO_ERROR,
                    "GOAWAY(NO_ERROR) from peer before response complete"))
            end
        end
    end

    final_state = pending[stream_id]
    body = take!(final_state.response_body)

    status = 0
    for (name, value) in final_state.response_headers
        if name == ":status"
            status = parse(Int, value)
            break
        end
    end

    return (status = status,
            headers = final_state.response_headers,
            body = body)
end
