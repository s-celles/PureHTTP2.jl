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
    # Inspection test for FR-013: the handler docs page MUST name
    # the future streaming extension points so downstream consumers
    # can plan around the forward-compat promise. This is the US3
    # (deferred streaming) acceptance test — it does NOT exercise
    # any runtime streaming behavior.
    docs_path = joinpath(@__DIR__, "..", "docs", "src", "handler.md")
    @test isfile(docs_path)

    content = read(docs_path, String)
    @test occursin("Future: streaming", content)
    @test occursin("Base.read(req", content)
    # `flush` must be named as the write-side future extension
    # point, and the Response type must be named somewhere on
    # the page (not necessarily adjacent).
    @test occursin("flush", content)
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
