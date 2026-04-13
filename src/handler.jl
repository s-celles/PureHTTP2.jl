import Base: flush

# Milestone 8: first-class request-handler API.
#
# `serve_with_handler!` is the high-level server-side entry point:
# it drives the HTTP/2 protocol plumbing (preface, SETTINGS, PING,
# GOAWAY, flow control, frame read/write) like `serve_connection!`
# from M5 does, AND additionally dispatches an application-level
# handler callback once per completed request stream. Application
# code never has to touch `process_preface`, `process_frame`,
# `encode_frame`, or the raw `conn.streams` scan — those plumbing
# concerns stay inside this module.
#
# NOTE ON FRAME-LOOP DUPLICATION: the inner read/write loop below
# reproduces ~30 lines from `src/serve.jl`'s `serve_connection!` so
# that a handler-dispatch hook can be injected after each
# `process_frame` call without touching `src/serve.jl`. Refactoring
# serve.jl to extract a shared loop helper is deferred to a future
# milestone — see `specs/011-request-handler-api/research.md` R-012
# for the trade-off rationale.
#
# The IO adapter contract is the same as M5's `serve_connection!`:
#
#   * `read(io, n::Int) :: Vector{UInt8}`  — read exactly `n` bytes,
#     returns fewer than `n` only on EOF.
#   * `write(io, bytes)`                    — write all bytes.
#   * `close(io)`                            — terminate the transport
#     (caller's responsibility, not serve_with_handler!'s).

# -- Request -----------------------------------------------------------

"""
    Request

Read-only view of an incoming HTTP/2 request passed to a handler
function by [`serve_with_handler!`](@ref). Handlers access the
request via the exported accessor functions
([`request_method`](@ref), [`request_path`](@ref),
[`request_authority`](@ref), [`request_headers`](@ref),
[`request_header`](@ref), [`request_body`](@ref),
[`request_trailers`](@ref)).

The struct's internal fields (`conn`, `stream`) are not part of
the public API — they are implementation details subject to
change. Handler code MUST use the accessor functions instead of
direct field access.

A `Request` is valid only for the duration of the handler call
that received it. Retaining references past the handler return
is undefined behavior because the backing stream may be removed
from the connection's internal state afterwards.

# Forward-compatibility

This milestone (v0.4.0) ships a buffered-body `request_body(req)`
accessor only. A future milestone may add
`Base.read(req::Request, n::Integer) -> Vector{UInt8}` for
incremental body reads before END_STREAM. Existing code calling
`request_body` will continue to work unchanged when that extension
lands — the two modes will be documented as mutually exclusive
per `Request` instance.
"""
struct Request
    conn::HTTP2Connection
    stream::HTTP2Stream
end

"""
    request_method(req::Request) -> Union{String, Nothing}

Return the `:method` pseudo-header of the request, or `nothing`
if the request did not carry one (malformed).
"""
request_method(req::Request) = get_method(req.stream)

"""
    request_path(req::Request) -> Union{String, Nothing}

Return the `:path` pseudo-header of the request, or `nothing` if
the request did not carry one (malformed).
"""
request_path(req::Request) = get_path(req.stream)

"""
    request_authority(req::Request) -> Union{String, Nothing}

Return the `:authority` pseudo-header of the request, or `nothing`
if the request did not carry one.
"""
request_authority(req::Request) = get_authority(req.stream)

"""
    request_headers(req::Request) -> Vector{Tuple{String, String}}

Return a fresh copy of the full request header list, including
pseudo-headers (`:method`, `:path`, `:scheme`, `:authority`) in
the order the client sent them. Handler mutation of the returned
vector is safe and does not affect the connection's internal
state.
"""
request_headers(req::Request) = copy(req.stream.request_headers)

"""
    request_header(req::Request, name::AbstractString) -> Union{String, Nothing}

Return the value of the first header named `name` on the request,
or `nothing` if the header is not present. Name lookup is
case-insensitive.
"""
request_header(req::Request, name::AbstractString) = get_header(req.stream, String(name))

"""
    request_body(req::Request) -> Vector{UInt8}

Return the full request body as a byte vector. Returns `UInt8[]`
if the request had no body. This accessor is buffered — it
returns the complete body accumulated on the stream as of the
moment the handler was invoked (i.e., after END_STREAM was
received from the peer).

A future milestone may add an incremental-read companion
`Base.read(req::Request, n::Integer)` for streaming handlers; see
the `Request` docstring and `docs/src/handler.md` for the
forward-compatibility contract.
"""
request_body(req::Request) = get_data(req.stream)

"""
    request_trailers(req::Request) -> Vector{Tuple{String, String}}

Return a fresh copy of the trailing header list (RFC 9113 §8.1).
Returns an empty vector if the client did not send trailers.
Trailers and leading headers are kept in separate lists — use
[`request_headers`](@ref) for leading headers.
"""
request_trailers(req::Request) = copy(req.stream.trailers)

# -- Response ----------------------------------------------------------

"""
    Response

Write-accumulator for the outgoing HTTP/2 response passed to a
handler function by [`serve_with_handler!`](@ref). Handlers build
the response by calling the exported mutator functions
([`set_status!`](@ref), [`set_header!`](@ref),
[`write_body!`](@ref)). The server finalizes the response (emits
HEADERS + DATA frames + END_STREAM) when the handler returns.

# Fields

- `status::Int` — Response status code, default `200`. Written by
  [`set_status!`](@ref). Serialized as the `:status` pseudo-header
  during finalization.
- `headers::Vector{Tuple{String, String}}` — Application response
  headers (excluding `:status`). Written by
  [`set_header!`](@ref). Multiple calls with the same name append
  rather than replace.
- `body::Vector{UInt8}` — Accumulated response body bytes. Written
  by [`write_body!`](@ref). Emitted as one or more DATA frames
  during finalization.

Internal fields (`conn`, `stream_id`, `finalized`) are not part
of the public API.

# Auto-finalization

When the handler function returns normally, the server emits the
accumulated response frames and sets `finalized = true`. After
finalization, mutator calls are no-ops that log `@warn`. If the
handler throws an exception, the server resets the affected
stream with `INTERNAL_ERROR` instead — see
[`serve_with_handler!`](@ref) for the full error-path contract.

# Forward-compatibility

This milestone (v0.4.0) ships a buffered-write `write_body!(res, bytes)`
accessor only. A future milestone may add `flush(res::Response)`
for incremental response-body emission between `write_body!`
calls. Existing buffered handlers will continue to work unchanged
when that extension lands.
"""
mutable struct Response
    conn::HTTP2Connection
    stream_id::UInt32
    io::Union{IO, Nothing}
    status::Int
    headers::Vector{Tuple{String, String}}
    body::Vector{UInt8}
    finalized::Bool
    headers_sent::Bool

    function Response(conn::HTTP2Connection, stream_id::UInt32)
        return new(conn, stream_id, nothing, 200,
                   Tuple{String, String}[], UInt8[], false, false)
    end
end

"""
    set_status!(res::Response, code::Integer) -> Response

Set the response `:status` pseudo-header to `code`. No validation
is performed — any integer is accepted. Returns `res` for
chaining.

After the response HEADERS have been emitted on the wire (either
by a prior [`flush(res)`](@ref Base.flush) call or by the server's
finalize path), this function becomes a no-op that logs
`@warn "Response headers already on the wire"`. Handlers that
want to mutate the status must do so BEFORE the first flush.
"""
function set_status!(res::Response, code::Integer)
    if res.finalized
        @warn "Response already finalized; set_status! is a no-op"
        return res
    end
    if res.headers_sent
        @warn "Response headers already on the wire; set_status! is a no-op"
        return res
    end
    res.status = Int(code)
    return res
end

"""
    set_header!(res::Response, name::AbstractString, value::AbstractString) -> Response

Append an application header to the response. Multiple calls
with the same name append rather than replace — HTTP/2 allows
repeated headers (e.g., `Set-Cookie`). Do NOT use this function
for the `:status` pseudo-header; use [`set_status!`](@ref)
instead. Returns `res` for chaining.

After the response HEADERS have been emitted on the wire (either
by a prior [`flush(res)`](@ref Base.flush) call or by the server's
finalize path), this function becomes a no-op that logs
`@warn "Response headers already on the wire"`. Handlers that
want to mutate response headers must do so BEFORE the first flush.
"""
function set_header!(res::Response, name::AbstractString, value::AbstractString)
    if res.finalized
        @warn "Response already finalized; set_header! is a no-op"
        return res
    end
    if res.headers_sent
        @warn "Response headers already on the wire; set_header! is a no-op"
        return res
    end
    push!(res.headers, (String(name), String(value)))
    return res
end

"""
    write_body!(res::Response, bytes::AbstractVector{UInt8}) -> Response
    write_body!(res::Response, str::AbstractString) -> Response

Append bytes to the response body buffer. The accumulated body
is emitted as one or more DATA frames during finalization. For
the `AbstractString` overload, the string is converted via
`codeunits(String(str))`.

Returns `res` for chaining.
"""
function write_body!(res::Response, bytes::AbstractVector{UInt8})
    if res.finalized
        @warn "Response already finalized; write_body! is a no-op"
        return res
    end
    append!(res.body, bytes)
    return res
end
function write_body!(res::Response, str::AbstractString)
    return write_body!(res, codeunits(String(str)))
end

# -- Base.flush(::Response) — streaming primitive ---------------------

"""
    Base.flush(res::Response) -> Response

Emit the currently-accumulated response body as HTTP/2 DATA
frame(s) immediately, without waiting for the handler function
to return. The first call to `flush(res)` on a response also
emits the response HEADERS frame carrying the current `res.status`
and `res.headers` list — this is the "lazy HEADERS" commit.

After a successful flush, `res.body` is empty and subsequent
`write_body!` calls start filling a fresh buffer. Multiple
flush/write cycles are the intended usage pattern for streaming
handlers:

```julia
serve_with_handler!(HTTP2Connection(), sock) do req, res
    set_status!(res, 200)
    set_header!(res, "content-type", "text/event-stream")
    for i in 1:5
        write_body!(res, "data: tick \$i\\n\\n")
        flush(res)       # push this event to the wire NOW
        sleep(1.0)
    end
end
```

# Non-terminal emission

`flush(res)` NEVER sets `END_STREAM` on its emitted frames. The
`END_STREAM` marker is emitted exclusively by the server's
finalize path when the handler function returns. This keeps the
semantics simple: `flush` = "commit some bytes", handler return
= "close the stream". A handler that calls flush and then
returns emits a separate zero-length DATA frame with END_STREAM
as the terminal marker — negligible (9 bytes) overhead, wire-legal
per RFC 9113 §6.1.

# Lazy HEADERS → mutator freeze

Once `flush(res)` has emitted HEADERS on the wire,
`set_status!` and `set_header!` become no-ops that log a
`@warn "Response headers already on the wire"`. Handlers that
need to mutate the response headers must do so BEFORE the
first flush. `write_body!` remains functional — it appends to
the now-emptied buffer for the next flush.

# Error path under streaming

If the handler throws after having flushed one or more chunks,
the wire sequence becomes HEADERS + DATA(chunk-1) + ... +
RST_STREAM(INTERNAL_ERROR). Bytes already on the wire cannot be
rolled back — this is inherent to streaming, not a bug. The
connection itself survives (other streams continue to be
served), matching the M8 error-path contract.

# Edge cases

- **Empty-body first flush**: emits HEADERS only (no DATA frame).
  Subsequent `write_body!` + `flush` works normally.
- **Empty-body subsequent flush**: total no-op — no HEADERS
  re-emission, no DATA frame, no `@warn`.
- **Flush on a finalized response**: no-op with
  `@warn "Response already finalized; flush is a no-op"`.
- **Flush on a response with no attached transport**
  (`res.io === nothing`): throws `ArgumentError`. This only
  happens if the `Response` was constructed outside
  `serve_with_handler!`; normal handler code never reaches
  this branch.

# Forward compatibility

This method has a single positional argument. Future releases
may add an optional keyword argument (e.g.,
`end_stream::Bool=false`) as a pure addition without breaking
any existing call site.

A companion read-side primitive `Base.read(req::Request, n::Integer)`
for incremental request-body reads remains **reserved** as a
forward-compat extension point — not shipped in v0.5.0. See
`docs/src/handler.md` "Future: request-side streaming" for the
status.

Returns `res` for chaining.
"""
function Base.flush(res::Response)
    if res.finalized
        @warn "Response already finalized; flush is a no-op"
        return res
    end
    if res.io === nothing
        throw(ArgumentError(
            "flush(res) called on a Response not attached to a transport — " *
            "this can only be called from inside a handler"))
    end

    # Emit HEADERS on the first flush only. Subsequent flushes
    # skip this step.
    if !res.headers_sent
        resp_headers = Tuple{String, String}[(":status", string(res.status))]
        append!(resp_headers, res.headers)
        for f in send_headers(res.conn, res.stream_id, resp_headers; end_stream=false)
            write(res.io, encode_frame(f))
        end
        res.headers_sent = true
    end

    # Emit DATA frame(s) if there are bytes to flush. Empty body
    # after the HEADERS-emitted path is a no-op.
    if !isempty(res.body)
        for f in send_data(res.conn, res.stream_id, res.body; end_stream=false)
            write(res.io, encode_frame(f))
        end
        empty!(res.body)
    end

    return res
end

# -- serve_with_handler! -----------------------------------------------

"""
    serve_with_handler!(handler, conn::HTTP2Connection, io::IO; max_frame_size::Int = DEFAULT_MAX_FRAME_SIZE) -> Nothing

Drive an [`HTTP2Connection`](@ref) over an arbitrary `Base.IO`
transport AND dispatch `handler` once per completed request
stream. This is PureHTTP2.jl's high-level server-side entry point —
the recommended replacement for `serve_connection!` when writing
application code that needs to respond to HTTP/2 requests.

The `handler` argument is a callable accepting two positional
arguments `(req::Request, res::Response)`. It is the first
positional argument to `serve_with_handler!` so Julia's `do`-block
syntax works:

```julia
serve_with_handler!(HTTP2Connection(), sock) do req, res
    set_status!(res, 200)
    write_body!(res, request_body(req))
end
```

# Lifecycle

1. Read and validate the 24-byte client preface. Throws
   `ConnectionError(PROTOCOL_ERROR)` on invalid or truncated
   preface.
2. Write the server preface (SETTINGS frame) to `io`.
3. Frame loop: read a frame header + payload, enforce
   `max_frame_size` (throws `ConnectionError(FRAME_SIZE_ERROR)`
   on violation), call [`process_frame`](@ref), write any
   response frames back to `io`.
4. After each `process_frame` call, scan `conn.streams` for
   streams whose `headers_complete && end_stream_received` is
   true and that have not yet been dispatched. For each such
   stream, construct a [`Request`](@ref) and a
   [`Response`](@ref), invoke `handler(req, res)` inside a
   `try` block, and emit the finalized response frames
   (normal return) or a RST_STREAM with `INTERNAL_ERROR` (on
   handler throw).
5. Exit cleanly on transport EOF (read returns fewer bytes than
   requested) or when the connection enters the `CLOSED` state
   (e.g., after a GOAWAY with a non-zero error code).

# Error-path contract

When the handler throws an exception, `serve_with_handler!`:

- Catches the exception — it is **never rethrown** to the caller.
- Logs `@warn "handler threw" stream_id=... exception=(err, bt)`.
- Emits `RST_STREAM(stream_id, INTERNAL_ERROR)` on the affected
  stream.
- Marks the associated `Response` as finalized.
- Continues the frame loop — other streams on the same connection
  continue to be served.

This guarantee means the caller's listen loop (typically
`while isopen(server); sock = accept(server); @async
serve_with_handler!(...); end`) is not killed by application
bugs.

# Concurrency model

Handlers are invoked **sequentially** in stream-close order by
the same task that drives the frame loop. There is no per-stream
`Task`, no write lock on `io`, and no output queue. A handler
that blocks on long-running IO stalls dispatch of other streams
on the same connection — this is a deliberate trade-off for
implementation simplicity at this milestone, documented in
`docs/src/handler.md`. Per-stream concurrency is a future
extension.

# Auto-finalization

When the handler returns normally, the server emits the
accumulated response frames (HEADERS + DATA(s) + END_STREAM)
based on the handler's mutations to `res`. The handler does NOT
need to explicitly signal end-of-stream — the server does it on
return.

# Forward-compatibility

This milestone ships a buffered-body API only. Incremental-read
(`Base.read(req, n)`) and incremental-write (`flush(res)`)
extensions are named as future additions in `docs/src/handler.md`
under "Future: streaming". Neither exists yet — existing code
calling `request_body` and `write_body!` will continue to work
unchanged when they land.

# Example

```julia
using PureHTTP2, Sockets

function echo_handler(req::Request, res::Response)
    set_status!(res, 200)
    set_header!(res, "content-type",
                something(request_header(req, "content-type"),
                          "application/octet-stream"))
    write_body!(res, request_body(req))
end

server = listen(IPv4("127.0.0.1"), 8787)
while isopen(server)
    sock = accept(server)
    @async try
        serve_with_handler!(echo_handler, HTTP2Connection(), sock)
    finally
        close(sock)
    end
end
```

See also: [`Request`](@ref), [`Response`](@ref),
[`serve_connection!`](@ref) (the low-level counterpart).
"""
function serve_with_handler!(handler, conn::HTTP2Connection, io::IO;
                              max_frame_size::Int = DEFAULT_MAX_FRAME_SIZE)
    # Step 1: read + validate client preface.
    preface_bytes = read(io, length(CONNECTION_PREFACE))
    if length(preface_bytes) < length(CONNECTION_PREFACE)
        throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
                              "Truncated connection preface"))
    end

    success, preface_response = process_preface(conn, preface_bytes)
    if !success
        throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
                              "Invalid connection preface"))
    end

    # Step 2: write server preface (SETTINGS).
    for frame in preface_response
        write(io, encode_frame(frame))
    end

    # Per-connection set of stream IDs that have already been
    # dispatched to the handler (normal return OR thrown). Prevents
    # re-invocation on subsequent frame-loop iterations while the
    # stream is still visible in `conn.streams`.
    dispatched = Set{UInt32}()

    # Step 3: frame read loop.
    while !is_closed(conn)
        header_bytes = read(io, FRAME_HEADER_SIZE)
        if length(header_bytes) < FRAME_HEADER_SIZE
            # Graceful EOF — transport closed by peer.
            break
        end

        header = decode_frame_header(header_bytes)

        if header.length > max_frame_size
            throw(ConnectionError(ErrorCode.FRAME_SIZE_ERROR,
                                  "Frame size $(header.length) exceeds max $(max_frame_size)"))
        end

        payload = if header.length == 0
            UInt8[]
        else
            read(io, Int(header.length))
        end
        if length(payload) < header.length
            throw(ConnectionError(ErrorCode.PROTOCOL_ERROR,
                                  "Truncated frame payload: got $(length(payload)) of $(header.length) bytes"))
        end

        response_frames = process_frame(conn, Frame(header, payload))
        for frame in response_frames
            write(io, encode_frame(frame))
        end

        # Step 4: post-process_frame dispatch hook.
        # Scan streams in ascending ID order for fresh completions.
        for stream_id in sort!(collect(keys(conn.streams)))
            stream_id in dispatched && continue
            stream = get_stream(conn, stream_id)
            stream === nothing && continue
            stream.headers_complete || continue
            stream.end_stream_received || continue

            req = Request(conn, stream)
            res = Response(conn, stream_id)
            res.io = io

            try
                handler(req, res)
            catch err
                # Error-path contract: never rethrow; reset the
                # affected stream with INTERNAL_ERROR; keep serving
                # other streams on this connection.
                @warn "handler threw" stream_id=stream_id exception=(err, catch_backtrace())
                res.finalized = true
                push!(dispatched, stream_id)
                try
                    rst = send_rst_stream(conn, stream_id,
                                          UInt32(ErrorCode.INTERNAL_ERROR))
                    write(io, encode_frame(rst))
                catch rst_err
                    # If we cannot even emit the RST_STREAM (e.g.,
                    # because the stream was already cleaned up or
                    # the connection is half-dead), swallow and
                    # continue — the listen loop must survive.
                    @warn "failed to emit RST_STREAM after handler throw" stream_id=stream_id exception=(rst_err, catch_backtrace())
                end
                continue
            end

            # Normal-return path: finalize the response.
            res.finalized = true
            push!(dispatched, stream_id)
            _finalize_response!(conn, io, stream_id, res)
        end
    end

    return nothing
end

# Internal: emit HEADERS + optional DATA frames for a completed
# handler invocation. Not exported — this is the finalizer
# called only by `serve_with_handler!`.
#
# Branches on `res.headers_sent`:
#
# - Branch A (`headers_sent == false`, M9/012 FR-009 byte-identical
#   to M8): handler never called flush. Emit HEADERS (with
#   END_STREAM on HEADERS if body is empty) + optional DATA frame
#   atomically.
#
# - Branch B (`headers_sent == true`, M9/012 streaming path): handler
#   called flush at least once, so HEADERS are already on the wire
#   and some or all of the body has already been emitted as
#   non-terminal DATA frames. Emit any remaining body as a
#   **terminal** DATA frame with END_STREAM. If no body is pending,
#   emit a zero-length DATA frame with END_STREAM as the terminal
#   marker (wire-legal per RFC 9113 §6.1).
function _finalize_response!(conn::HTTP2Connection, io::IO,
                             stream_id::UInt32, res::Response)
    if res.headers_sent
        # Branch B: streaming path. HEADERS already on the wire.
        # If body is empty, `send_data` returns no frames at all
        # (its inner loop is `while remaining > 0`), so we must
        # emit a zero-length DATA frame with END_STREAM by hand
        # to close the stream. Otherwise `send_data` produces the
        # terminal chunk(s) naturally with END_STREAM on the last.
        if isempty(res.body)
            terminal = data_frame(stream_id, UInt8[]; end_stream=true)
            write(io, encode_frame(terminal))
            # Update stream state to reflect that we sent END_STREAM.
            stream = get_stream(conn, stream_id)
            if stream !== nothing
                send_data!(stream, 0, true)
            end
        else
            for f in send_data(conn, stream_id, res.body; end_stream=true)
                write(io, encode_frame(f))
            end
        end
        return nothing
    end

    # Branch A: buffered path. Byte-identical to M8 (FR-009).
    resp_headers = Tuple{String, String}[(":status", string(res.status))]
    append!(resp_headers, res.headers)

    # If the body is empty, END_STREAM rides on the HEADERS frame —
    # no DATA frame is emitted at all. This matches the "empty body"
    # acceptance scenario.
    body_empty = isempty(res.body)
    for f in send_headers(conn, stream_id, resp_headers; end_stream=body_empty)
        write(io, encode_frame(f))
    end

    if !body_empty
        for f in send_data(conn, stream_id, res.body; end_stream=true)
            write(io, encode_frame(f))
        end
    end

    return nothing
end
