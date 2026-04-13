# Milestone 5: transport layer — IO-driven connection entry point.
#
# `serve_connection!` drives an `HTTP2Connection` over any `Base.IO`
# transport that satisfies the IO adapter contract documented in
# `specs/006-tls-alpn-support/contracts/README.md`:
#
#   * `read(io, n::Int) :: Vector{UInt8}`  — read exactly `n` bytes,
#     returns fewer than `n` only on EOF.
#   * `write(io, bytes)`                    — write all bytes.
#   * `close(io)`                            — terminate the transport
#     (caller's responsibility, not serve_connection!'s).
#
# Known-compatible transports at M5: `Base.IOBuffer` (with a small
# wrapper for bidirectional use), `Base.Pipe` / `Base.BufferStream`,
# `Sockets.TCPSocket`, and `OpenSSL.SSLStream`.

"""
    serve_connection!(conn::HTTP2Connection, io::IO; max_frame_size::Int = DEFAULT_MAX_FRAME_SIZE) -> Nothing

Drive an [`HTTP2Connection`](@ref) over an arbitrary `Base.IO` transport.

This is PureHTTP2.jl's primary server-side entry point for real traffic.
The function:

1. Reads the 24-byte client connection preface and validates it via
   [`process_preface`](@ref). On short read or invalid preface, throws
   [`ConnectionError`](@ref) with `PROTOCOL_ERROR`.
2. Writes the server preface (SETTINGS frame) to `io`.
3. Enters a read loop: read a 9-byte frame header via
   [`decode_frame_header`](@ref), enforce `header.length ≤ max_frame_size`
   (else throws `ConnectionError` with `FRAME_SIZE_ERROR`), read the
   payload, dispatch via [`process_frame`](@ref), and write any
   response frames back to `io`.
4. Exits cleanly when the transport reports EOF (read returns fewer
   bytes than requested) or when the connection enters the `CLOSED`
   state (e.g., after a GOAWAY with a non-zero error code).

The caller owns `io` and is responsible for closing it after this
function returns.

`max_frame_size` defaults to [`DEFAULT_MAX_FRAME_SIZE`](@ref) (16 KiB,
the RFC 9113 §6.5.2 default). Peers may negotiate a larger value via
SETTINGS; pass the negotiated value if known.

# Transport contract

See `specs/006-tls-alpn-support/contracts/README.md` for the full
contract. The minimum: `Base.read(io, n::Int)`, `Base.write(io, bytes)`,
`Base.close(io)`.

# Example

```julia
using PureHTTP2, Sockets

server = listen(8080)
while true
    sock = accept(server)
    @async begin
        conn = HTTP2Connection()
        try
            serve_connection!(conn, sock)
        finally
            close(sock)
        end
    end
end
```
"""
function serve_connection!(conn::HTTP2Connection, io::IO;
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
    end

    return nothing
end
