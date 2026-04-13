# Milestone 8: first-class request-handler API @testitems.
#
# These items exercise `PureHTTP2.serve_with_handler!` — the
# high-level server entry point that drives an HTTP/2 server
# connection AND dispatches an application-level handler callback
# once per completed request stream. They use paired
# `Base.BufferStream` instances as an in-memory bidirectional
# transport so the tests run in the main env with zero interop
# dependencies (same pattern as `testitems_client.jl` and
# `testitems_transport.jl`).
#
# TDD: all US1 items (T004–T008) are authored RED before the
# `serve_with_handler!` implementation lands in T011.

@testitem "Handler: buffered-body handler happy path" begin
    using PureHTTP2

    mutable struct HandlerPairedIO1 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerPairedIO1, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerPairedIO1, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerPairedIO1, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerPairedIO1) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    # Build client-side byte stream: preface + client SETTINGS +
    # HEADERS(POST /echo) + DATA("hello, echo", END_STREAM) +
    # GOAWAY(NO_ERROR) to end the loop cleanly.
    encoder = PureHTTP2.HPACKEncoder()
    request_headers = Tuple{String, String}[
        (":method",      "POST"),
        (":path",        "/echo"),
        (":scheme",      "http"),
        (":authority",   "127.0.0.1:8787"),
        ("content-type", "text/plain; charset=utf-8"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, request_headers)
    body_bytes = Vector{UInt8}("hello, echo")

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), body_bytes)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerPairedIO1(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    invocation_count = Ref(0)
    captured_method = Ref{Union{String, Nothing}}(nothing)
    captured_path = Ref{Union{String, Nothing}}(nothing)
    captured_authority = Ref{Union{String, Nothing}}(nothing)
    captured_body = Ref{Vector{UInt8}}(UInt8[])

    function echo_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        invocation_count[] += 1
        captured_method[] = PureHTTP2.request_method(req)
        captured_path[] = PureHTTP2.request_path(req)
        captured_authority[] = PureHTTP2.request_authority(req)
        captured_body[] = PureHTTP2.request_body(req)
        ct = something(PureHTTP2.request_header(req, "content-type"),
                       "application/octet-stream")
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.set_header!(res, "content-type", ct)
        PureHTTP2.write_body!(res, captured_body[])
    end

    PureHTTP2.serve_with_handler!(echo_handler, conn, server_io)

    @test invocation_count[] == 1
    @test captured_method[] == "POST"
    @test captured_path[] == "/echo"
    @test captured_authority[] == "127.0.0.1:8787"
    @test captured_body[] == body_bytes

    # Drain server response bytes.
    close(server_to_client)
    response_bytes = read(server_to_client)
    @test length(response_bytes) > 0

    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    # Server should have emitted: server preface SETTINGS,
    # SETTINGS ACK (reply to client SETTINGS), plus the handler's
    # response HEADERS(:status=200, stream=1) + DATA(body, stream=1, END_STREAM).
    stream1_frames = [f for f in decoded if f.header.stream_id == 1]
    @test length(stream1_frames) >= 2

    headers_frame = stream1_frames[1]
    @test headers_frame.header.frame_type == PureHTTP2.FrameType.HEADERS
    @test PureHTTP2.has_flag(headers_frame.header, PureHTTP2.FrameFlags.END_HEADERS)

    data_frame = stream1_frames[2]
    @test data_frame.header.frame_type == PureHTTP2.FrameType.DATA
    @test PureHTTP2.has_flag(data_frame.header, PureHTTP2.FrameFlags.END_STREAM)
    @test data_frame.payload == body_bytes

    # Byte-equivalence check (Principle III discharge): decode the
    # response HEADERS block and confirm :status=200 is present.
    decoder = PureHTTP2.HPACKDecoder()
    decoded_headers = PureHTTP2.decode_headers(decoder, headers_frame.payload)
    @test (":status", "200") in decoded_headers
end

@testitem "Handler: request with empty body" begin
    using PureHTTP2

    mutable struct HandlerPairedIO2 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerPairedIO2, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerPairedIO2, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerPairedIO2, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerPairedIO2) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    # GET request with END_STREAM set on the HEADERS frame directly
    # (no DATA frame at all — common idiom for body-less requests).
    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerPairedIO2(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    invocation_count = Ref(0)
    captured_body_len = Ref(0)

    function empty_body_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        invocation_count[] += 1
        captured_body_len[] = length(PureHTTP2.request_body(req))
        PureHTTP2.set_status!(res, 204)
    end

    PureHTTP2.serve_with_handler!(empty_body_handler, conn, server_io)

    @test invocation_count[] == 1
    @test captured_body_len[] == 0

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_frames = [f for f in decoded if f.header.stream_id == 1]
    # With an empty response body, the server MUST emit a HEADERS
    # frame with END_STREAM set and NO DATA frame at all.
    @test length(stream1_frames) == 1
    headers_frame = stream1_frames[1]
    @test headers_frame.header.frame_type == PureHTTP2.FrameType.HEADERS
    @test PureHTTP2.has_flag(headers_frame.header, PureHTTP2.FrameFlags.END_STREAM)

    decoder = PureHTTP2.HPACKDecoder()
    decoded_headers = PureHTTP2.decode_headers(decoder, headers_frame.payload)
    @test (":status", "204") in decoded_headers
end

@testitem "Handler: two interleaved streams on one connection" begin
    using PureHTTP2

    mutable struct HandlerPairedIO3 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerPairedIO3, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerPairedIO3, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerPairedIO3, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerPairedIO3) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    # Two interleaved client streams 1 and 3 with different bodies.
    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "POST"),
        (":path",      "/echo"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    # Each stream gets its own HEADERS frame, so each HPACK-encodes
    # against the evolving encoder state.
    block1 = PureHTTP2.encode_headers(encoder, req_headers)
    block3 = PureHTTP2.encode_headers(encoder, req_headers)
    body1 = Vector{UInt8}("stream-one-body")
    body3 = Vector{UInt8}("stream-three-body-different-length")

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    # HEADERS(stream=1) — NOT end_stream
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(1), block1)))
    # HEADERS(stream=3) — NOT end_stream
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(3), block3)))
    # DATA(stream=1, END_STREAM)
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), body1)))
    # DATA(stream=3, END_STREAM)
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(3), body3)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(3, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerPairedIO3(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    observed = Tuple{UInt32, Vector{UInt8}}[]

    function record_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        sid = req.stream.id
        b = PureHTTP2.request_body(req)
        push!(observed, (sid, b))
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.write_body!(res, b)
    end

    PureHTTP2.serve_with_handler!(record_handler, conn, server_io)

    @test length(observed) == 2
    sid_to_body = Dict(observed)
    @test sid_to_body[UInt32(1)] == body1
    @test sid_to_body[UInt32(3)] == body3

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_data_frames = [f for f in decoded
        if f.header.stream_id == 1 && f.header.frame_type == PureHTTP2.FrameType.DATA]
    stream3_data_frames = [f for f in decoded
        if f.header.stream_id == 3 && f.header.frame_type == PureHTTP2.FrameType.DATA]

    @test length(stream1_data_frames) >= 1
    @test length(stream3_data_frames) >= 1
    @test stream1_data_frames[1].payload == body1
    @test stream3_data_frames[1].payload == body3
end

@testitem "Handler: client disconnect before END_STREAM" begin
    using PureHTTP2

    mutable struct HandlerPairedIO4 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerPairedIO4, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerPairedIO4, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerPairedIO4, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerPairedIO4) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "POST"),
        (":path",      "/slow-upload"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    # Send preface + SETTINGS + HEADERS (NOT end_stream) + a partial
    # DATA frame with NO end_stream, then close the write side
    # simulating client disconnect before the request finishes.
    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        UInt8(0),  # NO end_stream
                        UInt32(1), Vector{UInt8}("partial"))))
    close(client_to_server)

    server_io = HandlerPairedIO4(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    invocation_count = Ref(0)
    function must_not_be_called(req::PureHTTP2.Request, res::PureHTTP2.Response)
        invocation_count[] += 1
        PureHTTP2.set_status!(res, 500)  # would mark the response
    end

    # serve_with_handler! should return cleanly on transport EOF
    # without rethrowing.
    PureHTTP2.serve_with_handler!(must_not_be_called, conn, server_io)

    @test invocation_count[] == 0
end

@testitem "Handler: handler throws exception emits RST_STREAM" begin
    using PureHTTP2
    using Test: @test_logs

    mutable struct HandlerPairedIO6 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerPairedIO6, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerPairedIO6, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerPairedIO6, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerPairedIO6) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "POST"),
        (":path",      "/boom"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)
    body_bytes = Vector{UInt8}("payload")

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), body_bytes)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerPairedIO6(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    function boom_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        error("synthetic handler failure")
    end

    # serve_with_handler! MUST NOT rethrow the handler exception.
    # @test_logs captures the expected @warn log (R-005 contract)
    # and simultaneously keeps test output clean.
    @test_logs (:warn, r"handler threw") match_mode=:any begin
        PureHTTP2.serve_with_handler!(boom_handler, conn, server_io)
    end

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_frames = [f for f in decoded if f.header.stream_id == 1]

    # A RST_STREAM frame with INTERNAL_ERROR MUST be present on
    # the affected stream.
    rst_frames = [f for f in stream1_frames
        if f.header.frame_type == PureHTTP2.FrameType.RST_STREAM]
    @test length(rst_frames) >= 1

    # RST_STREAM payload is a 4-byte big-endian error code.
    rst_payload = rst_frames[1].payload
    @test length(rst_payload) == 4
    error_code = (UInt32(rst_payload[1]) << 24) |
                 (UInt32(rst_payload[2]) << 16) |
                 (UInt32(rst_payload[3]) <<  8) |
                  UInt32(rst_payload[4])
    @test error_code == UInt32(PureHTTP2.ErrorCode.INTERNAL_ERROR)

    # The negative assertion: plan R-005 picked RST_STREAM, NOT
    # implicit :status=500 HEADERS. Verify no HEADERS frame was
    # emitted on the affected stream.
    headers_on_stream1 = [f for f in stream1_frames
        if f.header.frame_type == PureHTTP2.FrameType.HEADERS]
    @test isempty(headers_on_stream1)
end

@testitem "Handler: connection survives handler throw" begin
    using PureHTTP2
    using Test: @test_logs

    mutable struct HandlerPairedIO7 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerPairedIO7, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerPairedIO7, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerPairedIO7, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerPairedIO7) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "POST"),
        (":path",      "/echo"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    block1 = PureHTTP2.encode_headers(encoder, req_headers)
    block3 = PureHTTP2.encode_headers(encoder, req_headers)
    body1 = Vector{UInt8}("first request — will throw")
    body3 = Vector{UInt8}("second request — will succeed")

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(1), block1)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), body1)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(3), block3)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(3), body3)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(3, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerPairedIO7(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    invocation_count = Ref(0)
    function flaky_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        invocation_count[] += 1
        if invocation_count[] == 1
            error("first invocation fails")
        end
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.write_body!(res, PureHTTP2.request_body(req))
    end

    @test_logs (:warn, r"handler threw") match_mode=:any begin
        PureHTTP2.serve_with_handler!(flaky_handler, conn, server_io)
    end

    @test invocation_count[] == 2  # both streams reached the handler

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    # Stream 1: MUST have a RST_STREAM (first handler threw).
    stream1_rst = [f for f in decoded
        if f.header.stream_id == 1 &&
           f.header.frame_type == PureHTTP2.FrameType.RST_STREAM]
    @test length(stream1_rst) >= 1

    # Stream 3: MUST have a successful HEADERS(:status=200) + DATA
    # (second handler succeeded — connection survived the first
    # failure).
    stream3_headers = [f for f in decoded
        if f.header.stream_id == 3 &&
           f.header.frame_type == PureHTTP2.FrameType.HEADERS]
    stream3_data = [f for f in decoded
        if f.header.stream_id == 3 &&
           f.header.frame_type == PureHTTP2.FrameType.DATA]
    @test length(stream3_headers) == 1
    @test length(stream3_data) >= 1
    @test stream3_data[1].payload == body3

    decoder = PureHTTP2.HPACKDecoder()
    decoded_headers = PureHTTP2.decode_headers(decoder, stream3_headers[1].payload)
    @test (":status", "200") in decoded_headers
end

@testitem "Handler: forward-compat extension points documented" begin
    # Inspection test: in v0.5.0 (feature 012), write-side streaming
    # was promoted from reserved to live. The docs page MUST now
    # contain a live "Streaming" section with the @docs Base.flush
    # block, AND MUST still preserve the read-side streaming
    # reservation (Base.read(req, n) is still deferred).
    docs_path = joinpath(@__DIR__, "..", "docs", "src", "handler.md")
    @test isfile(docs_path)

    content = read(docs_path, String)
    # Live write-side streaming section (new in v0.5.0).
    @test occursin("## Streaming", content)
    # The @docs block for the new method must be present so the
    # docstring renders on the rendered page.
    @test occursin("Base.flush", content)
    # Read-side streaming remains reserved — the docs page still
    # names Base.read(req, n) as a future extension point.
    @test occursin("Base.read(req", content)
    # The Response type must still be documented on the page.
    @test occursin("Response", content)
end

@testitem "Handler: handler omits explicit end-of-response" begin
    using PureHTTP2

    mutable struct HandlerPairedIO5 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerPairedIO5, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerPairedIO5, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerPairedIO5, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerPairedIO5) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/hi"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerPairedIO5(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    # Handler writes a response body but never signals end_stream
    # explicitly — the server MUST auto-finalize on return.
    function simple_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.write_body!(res, "hi")
    end

    PureHTTP2.serve_with_handler!(simple_handler, conn, server_io)

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_frames = [f for f in decoded if f.header.stream_id == 1]
    @test length(stream1_frames) >= 2  # HEADERS + DATA

    # Verify END_STREAM is set on the LAST frame of stream 1 —
    # auto-finalization by the server, not by handler action.
    last_frame = stream1_frames[end]
    @test PureHTTP2.has_flag(last_frame.header, PureHTTP2.FrameFlags.END_STREAM)

    # And verify the body actually made it.
    data_frames = [f for f in stream1_frames
        if f.header.frame_type == PureHTTP2.FrameType.DATA]
    @test length(data_frames) >= 1
    @test data_frames[end].payload == Vector{UInt8}("hi")
end

# =====================================================================
# Milestone 9: streaming response bodies via `flush(res)` (US1 / US2 / US4).
#
# These items exercise `Base.flush(::PureHTTP2.Response)` — the
# write-side streaming primitive activated from M8's forward-compat
# reservation. They use the same paired `Base.BufferStream` transport
# pattern as the M8 items above.
# =====================================================================

@testitem "Handler: single flush emits DATA before handler return" begin
    using PureHTTP2

    mutable struct HandlerStreamingIO1 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerStreamingIO1, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerStreamingIO1, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerStreamingIO1, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerStreamingIO1) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "POST"),
        (":path",      "/stream"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    # Client sends preface + SETTINGS + HEADERS(END_HEADERS + END_STREAM)
    # so the handler can be invoked as soon as process_frame returns.
    # We use END_STREAM on HEADERS (no DATA frame) so the handler kicks
    # in without waiting for a body from the client.
    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerStreamingIO1(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    # Cooperative channel: handler blocks after its first flush until
    # the peer reader signals that it observed the first DATA frame.
    coordination = Channel{Int}(1)
    reader_err = Ref{Any}(nothing)
    first_chunk_payload = Ref{Vector{UInt8}}(UInt8[])
    second_chunk_payload = Ref{Vector{UInt8}}(UInt8[])

    function streaming_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.set_header!(res, "content-type", "application/octet-stream")
        PureHTTP2.write_body!(res, Vector{UInt8}("chunk-1"))
        flush(res)
        # Block until the peer reader has observed chunk-1 on the wire.
        take!(coordination)
        PureHTTP2.write_body!(res, Vector{UInt8}("chunk-2"))
        flush(res)
    end

    # Spawn the peer reader BEFORE serve_with_handler! runs.
    reader_task = @async try
        # Drain the outgoing stream incrementally — each call to
        # decode_frame blocks until the next full frame arrives.
        collected_frames = PureHTTP2.Frame[]
        stream1_data = PureHTTP2.Frame[]

        while length(stream1_data) < 1
            header_bytes = read(server_to_client, PureHTTP2.FRAME_HEADER_SIZE)
            length(header_bytes) == PureHTTP2.FRAME_HEADER_SIZE || break
            header = PureHTTP2.decode_frame_header(header_bytes)
            payload = header.length == 0 ? UInt8[] : read(server_to_client, Int(header.length))
            frame = PureHTTP2.Frame(header, payload)
            push!(collected_frames, frame)
            if frame.header.stream_id == 1 && frame.header.frame_type == PureHTTP2.FrameType.DATA
                push!(stream1_data, frame)
            end
        end

        first_chunk_payload[] = stream1_data[1].payload
        # Unblock the handler to emit chunk-2.
        put!(coordination, 1)

        # Continue reading until we see the second DATA frame.
        while length(stream1_data) < 2
            header_bytes = read(server_to_client, PureHTTP2.FRAME_HEADER_SIZE)
            length(header_bytes) == PureHTTP2.FRAME_HEADER_SIZE || break
            header = PureHTTP2.decode_frame_header(header_bytes)
            payload = header.length == 0 ? UInt8[] : read(server_to_client, Int(header.length))
            frame = PureHTTP2.Frame(header, payload)
            push!(collected_frames, frame)
            if frame.header.stream_id == 1 && frame.header.frame_type == PureHTTP2.FrameType.DATA
                push!(stream1_data, frame)
            end
        end
        second_chunk_payload[] = stream1_data[2].payload
    catch err
        reader_err[] = err
        # Make sure the handler isn't stuck waiting.
        isready(coordination) || put!(coordination, 0)
    end

    PureHTTP2.serve_with_handler!(streaming_handler, conn, server_io)
    close(server_to_client)
    wait(reader_task)

    @test reader_err[] === nothing
    @test first_chunk_payload[] == Vector{UInt8}("chunk-1")
    @test second_chunk_payload[] == Vector{UInt8}("chunk-2")
end

@testitem "Handler: multiple flushes emit distinct DATA frames" begin
    using PureHTTP2

    mutable struct HandlerStreamingIO2 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerStreamingIO2, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerStreamingIO2, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerStreamingIO2, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerStreamingIO2) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/multi"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerStreamingIO2(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    function multi_flush_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.write_body!(res, Vector{UInt8}("a"))
        flush(res)
        PureHTTP2.write_body!(res, Vector{UInt8}("bb"))
        flush(res)
        PureHTTP2.write_body!(res, Vector{UInt8}("ccc"))
        flush(res)
    end

    PureHTTP2.serve_with_handler!(multi_flush_handler, conn, server_io)

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_frames = [f for f in decoded if f.header.stream_id == 1]
    headers_frames = [f for f in stream1_frames
        if f.header.frame_type == PureHTTP2.FrameType.HEADERS]
    data_frames = [f for f in stream1_frames
        if f.header.frame_type == PureHTTP2.FrameType.DATA]

    # Exactly one HEADERS frame (emitted by the first flush).
    @test length(headers_frames) == 1

    # The three flushed body chunks PLUS a terminal zero-length DATA
    # frame from the streaming finalize path = 4 DATA frames total.
    @test length(data_frames) == 4
    @test data_frames[1].payload == Vector{UInt8}("a")
    @test data_frames[2].payload == Vector{UInt8}("bb")
    @test data_frames[3].payload == Vector{UInt8}("ccc")

    # The last DATA frame is the terminal marker: zero payload + END_STREAM.
    @test isempty(data_frames[4].payload)
    @test PureHTTP2.has_flag(data_frames[4].header, PureHTTP2.FrameFlags.END_STREAM)

    # Non-terminal flushes must NOT carry END_STREAM.
    for i in 1:3
        @test !PureHTTP2.has_flag(data_frames[i].header, PureHTTP2.FrameFlags.END_STREAM)
    end
end

@testitem "Handler: buffered-only handler wire-identical to M8" begin
    using PureHTTP2

    # FR-009 / SC-009 regression guard: a handler that NEVER calls
    # flush(res) must produce byte-identical frames to what M8 shipped.
    # This test reconstructs the expected wire bytes by calling
    # send_headers + send_data on a probe connection with matching
    # settings, then compares frame-by-frame against the actual output.

    mutable struct HandlerStreamingIO3 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerStreamingIO3, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerStreamingIO3, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerStreamingIO3, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerStreamingIO3) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "POST"),
        (":path",      "/buffered"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)
    body_bytes = Vector{UInt8}("hello-buffered")

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), body_bytes)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerStreamingIO3(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    # Canonical M8 buffered handler — sets status, sets a header,
    # writes body, returns. Never flushes.
    function buffered_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.set_header!(res, "content-type", "text/plain")
        PureHTTP2.set_header!(res, "content-length", string(length(body_bytes)))
        PureHTTP2.write_body!(res, body_bytes)
    end

    PureHTTP2.serve_with_handler!(buffered_handler, conn, server_io)

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded_actual = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded_actual, frame)
        pos[] += consumed
    end

    # Filter to stream-1 response frames (skipping server preface + SETTINGS ACK).
    actual_stream1 = [f for f in decoded_actual if f.header.stream_id == 1]

    # Build the expected frames via a hand-rolled send_headers + send_data
    # on a probe connection primed to the same HPACK encoder state as the
    # one serve_with_handler! used internally.
    probe_conn = PureHTTP2.HTTP2Connection()
    # Drive the probe's encoder through the same preface + client HEADERS
    # input the real connection saw, so HPACK dynamic-table state matches.
    preface_bytes_probe = Vector{UInt8}(PureHTTP2.CONNECTION_PREFACE)
    _ok, _resp = PureHTTP2.process_preface(probe_conn, preface_bytes_probe)
    # Replay the client settings frame.
    PureHTTP2.process_frame(probe_conn,
        PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[]))
    # Replay the client HEADERS so the probe has a stream-1 entry.
    PureHTTP2.process_frame(probe_conn,
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS,
                        UInt32(1), header_block))
    # Replay the client DATA with END_STREAM so the probe stream reaches
    # the half-closed (remote) state (matching what the real connection
    # saw when finalize ran).
    PureHTTP2.process_frame(probe_conn,
        PureHTTP2.Frame(PureHTTP2.FrameType.DATA,
                        PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), body_bytes))

    expected_resp_headers = Tuple{String, String}[
        (":status", "200"),
        ("content-type", "text/plain"),
        ("content-length", string(length(body_bytes))),
    ]
    expected_headers_frames = PureHTTP2.send_headers(probe_conn, UInt32(1),
        expected_resp_headers; end_stream=false)
    expected_data_frames = PureHTTP2.send_data(probe_conn, UInt32(1),
        body_bytes; end_stream=true)

    expected_stream1 = PureHTTP2.Frame[]
    append!(expected_stream1, expected_headers_frames)
    append!(expected_stream1, expected_data_frames)

    @test length(actual_stream1) == length(expected_stream1)
    for (a, e) in zip(actual_stream1, expected_stream1)
        @test a.header.frame_type == e.header.frame_type
        @test a.header.flags == e.header.flags
        @test a.header.stream_id == e.header.stream_id
        @test a.payload == e.payload
    end
end

@testitem "Handler: set_status! after flush is a no-op with warn" begin
    using PureHTTP2
    using Test: @test_logs

    mutable struct HandlerStreamingIO4 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerStreamingIO4, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerStreamingIO4, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerStreamingIO4, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerStreamingIO4) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/status-test"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerStreamingIO4(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    observed_status_after_attempt = Ref(0)

    function post_flush_status_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.write_body!(res, "before-flush")
        flush(res)
        PureHTTP2.set_status!(res, 500)  # MUST be a no-op
        observed_status_after_attempt[] = res.status
    end

    @test_logs (:warn, r"headers already on the wire") match_mode=:any begin
        PureHTTP2.serve_with_handler!(post_flush_status_handler, conn, server_io)
    end

    @test observed_status_after_attempt[] == 200

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_headers = [f for f in decoded
        if f.header.stream_id == 1 && f.header.frame_type == PureHTTP2.FrameType.HEADERS]
    @test length(stream1_headers) == 1

    decoder = PureHTTP2.HPACKDecoder()
    decoded_headers = PureHTTP2.decode_headers(decoder, stream1_headers[1].payload)
    @test (":status", "200") in decoded_headers
    @test !any(h -> h == (":status", "500"), decoded_headers)
end

@testitem "Handler: set_header! after flush is a no-op with warn" begin
    using PureHTTP2
    using Test: @test_logs

    mutable struct HandlerStreamingIO5 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerStreamingIO5, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerStreamingIO5, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerStreamingIO5, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerStreamingIO5) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/header-test"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerStreamingIO5(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    function post_flush_header_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.set_header!(res, "x-early", "yes")
        PureHTTP2.write_body!(res, "before-flush")
        flush(res)
        PureHTTP2.set_header!(res, "x-late", "oops")  # MUST be a no-op
    end

    @test_logs (:warn, r"headers already on the wire") match_mode=:any begin
        PureHTTP2.serve_with_handler!(post_flush_header_handler, conn, server_io)
    end

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_headers = [f for f in decoded
        if f.header.stream_id == 1 && f.header.frame_type == PureHTTP2.FrameType.HEADERS]
    @test length(stream1_headers) == 1

    decoder = PureHTTP2.HPACKDecoder()
    decoded_headers = PureHTTP2.decode_headers(decoder, stream1_headers[1].payload)
    @test (":status", "200") in decoded_headers
    @test ("x-early", "yes") in decoded_headers
    @test !any(h -> first(h) == "x-late", decoded_headers)
end

@testitem "Handler: write_body! still works after flush" begin
    using PureHTTP2

    mutable struct HandlerStreamingIO6 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerStreamingIO6, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerStreamingIO6, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerStreamingIO6, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerStreamingIO6) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/write-after-flush"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerStreamingIO6(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    function write_after_flush_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.write_body!(res, "first")
        flush(res)
        # write_body! must still work post-flush — buffer for next flush.
        PureHTTP2.write_body!(res, "second")
        PureHTTP2.write_body!(res, "third")
        flush(res)
    end

    PureHTTP2.serve_with_handler!(write_after_flush_handler, conn, server_io)

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_data = [f for f in decoded
        if f.header.stream_id == 1 && f.header.frame_type == PureHTTP2.FrameType.DATA]

    # Expected: DATA("first") from first flush + DATA("secondthird") from
    # second flush + zero-length DATA with END_STREAM from finalize = 3 frames.
    @test length(stream1_data) == 3
    @test stream1_data[1].payload == Vector{UInt8}("first")
    @test stream1_data[2].payload == Vector{UInt8}("secondthird")
    @test isempty(stream1_data[3].payload)
    @test PureHTTP2.has_flag(stream1_data[3].header, PureHTTP2.FrameFlags.END_STREAM)
end

@testitem "Handler: flush then throw emits RST_STREAM" begin
    using PureHTTP2
    using Test: @test_logs

    mutable struct HandlerStreamingIO7 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerStreamingIO7, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerStreamingIO7, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerStreamingIO7, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerStreamingIO7) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/boom-mid-stream"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, req_headers)

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), header_block)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(1, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerStreamingIO7(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    function flush_then_throw_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.write_body!(res, Vector{UInt8}("partial"))
        flush(res)
        error("boom after flush")
    end

    @test_logs (:warn, r"handler threw") match_mode=:any begin
        PureHTTP2.serve_with_handler!(flush_then_throw_handler, conn, server_io)
    end

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    stream1_frames = [f for f in decoded if f.header.stream_id == 1]

    headers_frames = [f for f in stream1_frames
        if f.header.frame_type == PureHTTP2.FrameType.HEADERS]
    data_frames = [f for f in stream1_frames
        if f.header.frame_type == PureHTTP2.FrameType.DATA]
    rst_frames = [f for f in stream1_frames
        if f.header.frame_type == PureHTTP2.FrameType.RST_STREAM]

    # HEADERS was emitted by the flush before the throw.
    @test length(headers_frames) == 1
    # Exactly one DATA frame (the flushed "partial") — NO zero-length
    # terminal DATA from finalize (the error branch must skip finalize).
    @test length(data_frames) == 1
    @test data_frames[1].payload == Vector{UInt8}("partial")
    @test !PureHTTP2.has_flag(data_frames[1].header, PureHTTP2.FrameFlags.END_STREAM)
    # RST_STREAM with INTERNAL_ERROR on the affected stream.
    @test length(rst_frames) >= 1
    rst_payload = rst_frames[1].payload
    @test length(rst_payload) == 4
    error_code = (UInt32(rst_payload[1]) << 24) |
                 (UInt32(rst_payload[2]) << 16) |
                 (UInt32(rst_payload[3]) <<  8) |
                  UInt32(rst_payload[4])
    @test error_code == UInt32(PureHTTP2.ErrorCode.INTERNAL_ERROR)
end

@testitem "Handler: connection survives streaming handler throw" begin
    using PureHTTP2
    using Test: @test_logs

    mutable struct HandlerStreamingIO8 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::HandlerStreamingIO8, n::Int) = read(io.incoming, n)
    Base.write(io::HandlerStreamingIO8, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::HandlerStreamingIO8, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::HandlerStreamingIO8) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    req_headers = Tuple{String, String}[
        (":method",    "GET"),
        (":path",      "/survive-streaming-throw"),
        (":scheme",    "http"),
        (":authority", "127.0.0.1:8787"),
    ]
    block1 = PureHTTP2.encode_headers(encoder, req_headers)
    block3 = PureHTTP2.encode_headers(encoder, req_headers)

    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(1), block1)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                        PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                        UInt32(3), block3)))
    write(client_to_server, PureHTTP2.encode_frame(
        PureHTTP2.goaway_frame(3, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    server_io = HandlerStreamingIO8(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    invocation_count = Ref(0)
    function streaming_flaky_handler(req::PureHTTP2.Request, res::PureHTTP2.Response)
        invocation_count[] += 1
        if invocation_count[] == 1
            PureHTTP2.set_status!(res, 200)
            PureHTTP2.write_body!(res, Vector{UInt8}("stream-1-partial"))
            flush(res)
            error("first invocation fails mid-stream")
        end
        # Second invocation: normal successful response.
        PureHTTP2.set_status!(res, 200)
        PureHTTP2.write_body!(res, Vector{UInt8}("stream-3-ok"))
    end

    @test_logs (:warn, r"handler threw") match_mode=:any begin
        PureHTTP2.serve_with_handler!(streaming_flaky_handler, conn, server_io)
    end

    @test invocation_count[] == 2

    close(server_to_client)
    response_bytes = read(server_to_client)
    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    # Stream 1: HEADERS + DATA("stream-1-partial") + RST_STREAM.
    stream1_rst = [f for f in decoded
        if f.header.stream_id == 1 &&
           f.header.frame_type == PureHTTP2.FrameType.RST_STREAM]
    @test length(stream1_rst) >= 1

    # Stream 3: normal HEADERS + DATA("stream-3-ok") + END_STREAM — the
    # connection survived stream 1's mid-stream throw.
    stream3_headers = [f for f in decoded
        if f.header.stream_id == 3 &&
           f.header.frame_type == PureHTTP2.FrameType.HEADERS]
    stream3_data = [f for f in decoded
        if f.header.stream_id == 3 &&
           f.header.frame_type == PureHTTP2.FrameType.DATA]
    @test length(stream3_headers) == 1
    @test length(stream3_data) >= 1
    @test stream3_data[1].payload == Vector{UInt8}("stream-3-ok")
    @test PureHTTP2.has_flag(stream3_data[end].header, PureHTTP2.FrameFlags.END_STREAM)

    decoder = PureHTTP2.HPACKDecoder()
    decoded_s3_headers = PureHTTP2.decode_headers(decoder, stream3_headers[1].payload)
    @test (":status", "200") in decoded_s3_headers
end
