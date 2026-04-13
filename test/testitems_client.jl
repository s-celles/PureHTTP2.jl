# Milestone 6: client-role @testitems.
#
# These items exercise `PureHTTP2.open_connection!` over in-memory
# `Base.IO` transports using paired `Base.BufferStream` instances
# as a bidirectional pipe. Each item pre-populates the server→client
# stream with a canned response sequence, then calls the client
# pump and asserts the outcome.
#
# Happy-path items (US1): stream ID parity, basic request/response,
# END_STREAM on HEADERS, CONTINUATION reassembly, DATA body
# collection.
#
# Error-path items (US3): RST_STREAM, graceful GOAWAY (NO_ERROR),
# fatal GOAWAY (PROTOCOL_ERROR), PUSH_PROMISE rejection,
# FRAME_SIZE_ERROR enforcement.

@testitem "Client: stream ID parity is odd" begin
    using PureHTTP2

    mutable struct PairedIO1 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO1, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO1, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO1, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO1) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    # Preload the server response: server SETTINGS + SETTINGS ACK +
    # HEADERS(END_STREAM) — a minimal 200 OK.
    server_headers = Tuple{String, String}[(":status", "200")]
    decoder_probe = PureHTTP2.HPACKEncoder()
    header_block = PureHTTP2.encode_headers(decoder_probe, server_headers)

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))
    resp = PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                       PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                       UInt32(1), header_block)
    write(server_to_client, PureHTTP2.encode_frame(resp))

    io = PairedIO1(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()
    # Use a client HPACK encoder that shares the decoder's view by
    # letting the real client do both sides of HPACK itself.
    PureHTTP2.open_connection!(conn, io;
        request_headers = Tuple{String, String}[
            (":method", "GET"), (":path", "/"),
            (":scheme", "http"), (":authority", "example.com")])

    # The client should have written to client_to_server. Drain and
    # verify the first frame after the preface is HEADERS on an odd
    # stream ID.
    close(client_to_server)
    client_bytes = read(client_to_server)
    @test length(client_bytes) > 24
    @test client_bytes[1:24] == Vector{UInt8}(PureHTTP2.CONNECTION_PREFACE)

    # Skip the preface (24 bytes) and the client SETTINGS frame.
    pos = 25
    frame1, consumed1 = PureHTTP2.decode_frame(@view client_bytes[pos:end])
    @test frame1.header.frame_type == PureHTTP2.FrameType.SETTINGS
    pos += consumed1

    # Next should be the request HEADERS frame.
    frame2, _consumed2 = PureHTTP2.decode_frame(@view client_bytes[pos:end])
    @test frame2.header.frame_type == PureHTTP2.FrameType.HEADERS
    @test frame2.header.stream_id == 1
    @test frame2.header.stream_id % 2 == 1  # odd
end

@testitem "Client: open_connection! with BufferStream pair" begin
    using PureHTTP2

    mutable struct PairedIO2 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO2, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO2, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO2, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO2) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    # Preload: server SETTINGS + SETTINGS_ACK + HEADERS(END_STREAM).
    encoder = PureHTTP2.HPACKEncoder()
    response_headers = Tuple{String, String}[
        (":status", "200"),
        ("content-type", "text/plain"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, response_headers)

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))
    resp_frame = PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                             PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                             UInt32(1), header_block)
    write(server_to_client, PureHTTP2.encode_frame(resp_frame))

    io = PairedIO2(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()
    result = PureHTTP2.open_connection!(conn, io;
        request_headers = Tuple{String, String}[
            (":method", "GET"), (":path", "/"),
            (":scheme", "http"), (":authority", "example.com")])

    @test result.status == 200
    @test (":status", "200") in result.headers
    @test result.body == UInt8[]
end

@testitem "Client: END_STREAM on response HEADERS" begin
    using PureHTTP2

    mutable struct PairedIO3 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO3, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO3, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO3, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO3) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    response_headers = Tuple{String, String}[(":status", "204")]
    header_block = PureHTTP2.encode_headers(encoder, response_headers)

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))
    resp = PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                      PureHTTP2.FrameFlags.END_HEADERS | PureHTTP2.FrameFlags.END_STREAM,
                      UInt32(1), header_block)
    write(server_to_client, PureHTTP2.encode_frame(resp))

    io = PairedIO3(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()
    result = PureHTTP2.open_connection!(conn, io;
        request_headers = Tuple{String, String}[
            (":method", "GET"), (":path", "/no-body"),
            (":scheme", "http"), (":authority", "example.com")])

    @test result.status == 204
    @test isempty(result.body)
    # Stream was closed cleanly on HEADERS with END_STREAM (half-
    # closed → closed transition).
end

@testitem "Client: server splits HEADERS across CONTINUATION" begin
    using PureHTTP2

    mutable struct PairedIO4 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO4, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO4, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO4, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO4) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    # Encode all headers as one block but split the bytes manually
    # across HEADERS + CONTINUATION frames.
    encoder = PureHTTP2.HPACKEncoder()
    response_headers = Tuple{String, String}[
        (":status", "200"),
        ("x-header-one", "value-one"),
        ("x-header-two", "value-two"),
    ]
    full_block = PureHTTP2.encode_headers(encoder, response_headers)
    split = max(1, div(length(full_block), 2))
    part1 = full_block[1:split]
    part2 = full_block[(split + 1):end]

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))

    # HEADERS frame with END_STREAM but NOT END_HEADERS — part1 of
    # the header block.
    h1 = PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                     PureHTTP2.FrameFlags.END_STREAM,
                     UInt32(1), part1)
    write(server_to_client, PureHTTP2.encode_frame(h1))

    # CONTINUATION frame with END_HEADERS — part2.
    h2 = PureHTTP2.Frame(PureHTTP2.FrameType.CONTINUATION,
                     PureHTTP2.FrameFlags.END_HEADERS,
                     UInt32(1), part2)
    write(server_to_client, PureHTTP2.encode_frame(h2))

    io = PairedIO4(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()
    result = PureHTTP2.open_connection!(conn, io;
        request_headers = Tuple{String, String}[
            (":method", "GET"), (":path", "/"),
            (":scheme", "http"), (":authority", "example.com")])

    @test result.status == 200
    @test (":status", "200") in result.headers
    @test ("x-header-one", "value-one") in result.headers
    @test ("x-header-two", "value-two") in result.headers
end

@testitem "Client: DATA body collection" begin
    using PureHTTP2

    mutable struct PairedIO5 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO5, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO5, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO5, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO5) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    encoder = PureHTTP2.HPACKEncoder()
    response_headers = Tuple{String, String}[
        (":status", "200"),
        ("content-type", "application/octet-stream"),
    ]
    header_block = PureHTTP2.encode_headers(encoder, response_headers)

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))

    # HEADERS without END_STREAM, then three DATA frames.
    h = PureHTTP2.Frame(PureHTTP2.FrameType.HEADERS,
                    PureHTTP2.FrameFlags.END_HEADERS,
                    UInt32(1), header_block)
    write(server_to_client, PureHTTP2.encode_frame(h))

    chunk1 = UInt8[0x41, 0x42, 0x43]  # "ABC"
    chunk2 = UInt8[0x44, 0x45]        # "DE"
    chunk3 = UInt8[0x46, 0x47, 0x48, 0x49]  # "FGHI"

    d1 = PureHTTP2.Frame(PureHTTP2.FrameType.DATA, UInt8(0), UInt32(1), chunk1)
    d2 = PureHTTP2.Frame(PureHTTP2.FrameType.DATA, UInt8(0), UInt32(1), chunk2)
    d3 = PureHTTP2.Frame(PureHTTP2.FrameType.DATA, PureHTTP2.FrameFlags.END_STREAM, UInt32(1), chunk3)

    write(server_to_client, PureHTTP2.encode_frame(d1))
    write(server_to_client, PureHTTP2.encode_frame(d2))
    write(server_to_client, PureHTTP2.encode_frame(d3))

    io = PairedIO5(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()
    result = PureHTTP2.open_connection!(conn, io;
        request_headers = Tuple{String, String}[
            (":method", "GET"), (":path", "/bin"),
            (":scheme", "http"), (":authority", "example.com")])

    @test result.status == 200
    @test result.body == vcat(chunk1, chunk2, chunk3)
    @test String(result.body) == "ABCDEFGHI"
end

@testitem "Client: receive RST_STREAM" begin
    using PureHTTP2

    mutable struct PairedIO6 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO6, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO6, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO6, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO6) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))
    # Server sends RST_STREAM with CANCEL on stream 1.
    rst = PureHTTP2.rst_stream_frame(UInt32(1), PureHTTP2.ErrorCode.CANCEL)
    write(server_to_client, PureHTTP2.encode_frame(rst))

    io = PairedIO6(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()

    err = try
        PureHTTP2.open_connection!(conn, io;
            request_headers = Tuple{String, String}[
                (":method", "GET"), (":path", "/"),
                (":scheme", "http"), (":authority", "example.com")])
        nothing
    catch e
        e
    end

    @test err isa PureHTTP2.StreamError
    @test err.stream_id == UInt32(1)
    @test err.error_code == PureHTTP2.ErrorCode.CANCEL
end

@testitem "Client: receive GOAWAY (NO_ERROR)" begin
    using PureHTTP2

    mutable struct PairedIO7 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO7, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO7, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO7, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO7) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))
    # GOAWAY(NO_ERROR) before any response HEADERS — server refuses
    # to serve the request gracefully. Client should raise a
    # ConnectionError because the response was never received.
    goaway = PureHTTP2.goaway_frame(0, PureHTTP2.ErrorCode.NO_ERROR)
    write(server_to_client, PureHTTP2.encode_frame(goaway))

    io = PairedIO7(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()

    err = try
        PureHTTP2.open_connection!(conn, io;
            request_headers = Tuple{String, String}[
                (":method", "GET"), (":path", "/"),
                (":scheme", "http"), (":authority", "example.com")])
        nothing
    catch e
        e
    end

    @test err isa PureHTTP2.ConnectionError
    @test conn.state == PureHTTP2.ConnectionState.CLOSING
end

@testitem "Client: receive GOAWAY (PROTOCOL_ERROR)" begin
    using PureHTTP2

    mutable struct PairedIO8 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO8, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO8, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO8, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO8) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))
    goaway = PureHTTP2.goaway_frame(0, PureHTTP2.ErrorCode.PROTOCOL_ERROR)
    write(server_to_client, PureHTTP2.encode_frame(goaway))

    io = PairedIO8(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()

    err = try
        PureHTTP2.open_connection!(conn, io;
            request_headers = Tuple{String, String}[
                (":method", "GET"), (":path", "/"),
                (":scheme", "http"), (":authority", "example.com")])
        nothing
    catch e
        e
    end

    @test err isa PureHTTP2.ConnectionError
    @test err.error_code == PureHTTP2.ErrorCode.PROTOCOL_ERROR
    @test conn.state == PureHTTP2.ConnectionState.CLOSED
end

@testitem "Client: reject PUSH_PROMISE when ENABLE_PUSH=0" begin
    using PureHTTP2

    mutable struct PairedIO9 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO9, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO9, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO9, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO9) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))

    # Hand-craft a PUSH_PROMISE frame targeting stream 1. Payload:
    # 4 bytes promised stream ID (2, even) + arbitrary header block.
    push_payload = UInt8[0x00, 0x00, 0x00, 0x02,  # promised stream = 2
                         0x00]  # empty header block (invalid but OK for error test)
    push = PureHTTP2.Frame(PureHTTP2.FrameType.PUSH_PROMISE,
                       PureHTTP2.FrameFlags.END_HEADERS,
                       UInt32(1), push_payload)
    write(server_to_client, PureHTTP2.encode_frame(push))

    io = PairedIO9(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()

    err = try
        PureHTTP2.open_connection!(conn, io;
            request_headers = Tuple{String, String}[
                (":method", "GET"), (":path", "/"),
                (":scheme", "http"), (":authority", "example.com")])
        nothing
    catch e
        e
    end

    @test err isa PureHTTP2.ConnectionError
    @test err.error_code == PureHTTP2.ErrorCode.PROTOCOL_ERROR
end

@testitem "Client: frame size exceeding max_frame_size" begin
    using PureHTTP2

    mutable struct PairedIO10 <: IO
        incoming::Base.BufferStream
        outgoing::Base.BufferStream
    end
    Base.read(io::PairedIO10, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO10, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO10, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO10) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    # Server sends a frame header claiming length = 32768 (2x default
    # max of 16384). Use a small max_frame_size limit on the client
    # side to trigger FRAME_SIZE_ERROR on the very first frame after
    # the handshake.
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(server_to_client, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))

    # Bad frame header: length 100, type DATA, flags 0, stream 1.
    # Follow with 100 payload bytes so the frame is well-formed
    # enough to read — but max_frame_size=50 will reject it.
    bad_header = UInt8[
        0x00, 0x00, 0x64,  # length = 100
        UInt8(PureHTTP2.FrameType.DATA),
        0x00,              # flags
        0x00, 0x00, 0x00, 0x01,  # stream 1
    ]
    write(server_to_client, bad_header)
    write(server_to_client, zeros(UInt8, 100))

    io = PairedIO10(server_to_client, client_to_server)
    conn = PureHTTP2.HTTP2Connection()

    err = try
        PureHTTP2.open_connection!(conn, io;
            request_headers = Tuple{String, String}[
                (":method", "GET"), (":path", "/"),
                (":scheme", "http"), (":authority", "example.com")],
            max_frame_size = 50)
        nothing
    catch e
        e
    end

    @test err isa PureHTTP2.ConnectionError
    @test err.error_code == PureHTTP2.ErrorCode.FRAME_SIZE_ERROR
end
