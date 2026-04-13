# h2c echo server using PureHTTP2.jl.
#
# Drives the protocol frame loop manually (instead of
# `PureHTTP2.serve_connection!`) so we can inject an application-level
# echo between frame reads: whenever a request completes
# (headers_complete && end_stream_received), the server replies with
# HTTP/2 status 200 and DATA frames whose payload is the request body
# verbatim.
#
# Run:
#     julia --project=. examples/echo/server.jl
#
# Then in another terminal:
#     julia --project=. examples/echo/client.jl "hello, echo"

using PureHTTP2
using Sockets

function handle_connection(sock::TCPSocket)
    conn = HTTP2Connection()

    preface_bytes = read(sock, length(CONNECTION_PREFACE))
    if length(preface_bytes) < length(CONNECTION_PREFACE)
        error("Truncated connection preface")
    end
    ok, preface_response = process_preface(conn, preface_bytes)
    ok || error("Invalid connection preface")
    for frame in preface_response
        write(sock, encode_frame(frame))
    end

    echoed = Set{UInt32}()
    while !is_closed(conn)
        header_bytes = read(sock, FRAME_HEADER_SIZE)
        if length(header_bytes) < FRAME_HEADER_SIZE
            break
        end
        header = decode_frame_header(header_bytes)
        payload = header.length == 0 ? UInt8[] : read(sock, Int(header.length))
        if length(payload) < header.length
            error("Truncated frame payload")
        end

        for f in process_frame(conn, Frame(header, payload))
            write(sock, encode_frame(f))
        end

        for stream_id in collect(keys(conn.streams))
            stream_id in echoed && continue
            stream = get_stream(conn, stream_id)
            stream === nothing && continue
            stream.headers_complete || continue
            stream.end_stream_received || continue

            body = get_data(stream)
            req_ct = get_header(stream, "content-type")
            resp_ct = req_ct === nothing ? "application/octet-stream" : req_ct

            @info "echo" stream_id=stream_id method=get_method(stream) path=get_path(stream) bytes=length(body)

            resp_headers = Tuple{String, String}[
                (":status",        "200"),
                ("content-type",   resp_ct),
                ("content-length", string(length(body))),
                ("server",         "PureHTTP2.jl-echo-example"),
            ]

            for f in send_headers(conn, stream_id, resp_headers; end_stream=false)
                write(sock, encode_frame(f))
            end
            for f in send_data(conn, stream_id, body; end_stream=true)
                write(sock, encode_frame(f))
            end

            push!(echoed, stream_id)
        end
    end
end

function main(; host=IPv4("127.0.0.1"), port::Int=8787)
    server = listen(host, port)
    @info "echo server listening" host=string(host) port=port
    try
        while isopen(server)
            sock = accept(server)
            @async try
                handle_connection(sock)
            catch err
                @warn "connection terminated" exception=(err, catch_backtrace())
            finally
                close(sock)
            end
        end
    finally
        close(server)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
