# Milestone 5: Transport layer @testitems.
#
# These items exercise `PureHTTP2.serve_connection!` over in-memory
# `Base.IO` transports that satisfy the IO adapter contract documented
# in `specs/006-tls-alpn-support/contracts/README.md`.
#
# They also guard the optional OpenSSL.jl extension pattern: in the
# main env (no OpenSSL), `PureHTTP2.set_alpn_h2!` MUST exist as a generic
# function with zero methods. The live-method cross-test lives in the
# interop env (`test/interop/testitems_interop.jl`).

@testitem "Transport: serve_connection! with IOBuffer" begin
    using PureHTTP2

    # Minimal `IO` wrapper so the server reads from one buffer and
    # writes to another (Base.IOBuffer has a single position cursor
    # and cannot serve bidirectional traffic without this split).
    mutable struct SplitIO <: IO
        input::IOBuffer
        output::IOBuffer
    end
    Base.read(io::SplitIO, n::Int) = read(io.input, n)
    Base.write(io::SplitIO, x::UInt8) = write(io.output, x)
    Base.unsafe_write(io::SplitIO, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.output, p, n)
    Base.close(io::SplitIO) = (close(io.input); close(io.output))
    Base.eof(io::SplitIO) = eof(io.input)

    # Build the client byte stream: preface + SETTINGS + SETTINGS ACK
    # + PING + GOAWAY(NO_ERROR).
    client_bytes = IOBuffer()
    write(client_bytes, PureHTTP2.CONNECTION_PREFACE)
    write(client_bytes, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_bytes, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))
    write(client_bytes, PureHTTP2.encode_frame(PureHTTP2.ping_frame(UInt8[1,2,3,4,5,6,7,8])))
    write(client_bytes, PureHTTP2.encode_frame(PureHTTP2.goaway_frame(0, PureHTTP2.ErrorCode.NO_ERROR)))

    input_buf = IOBuffer(take!(client_bytes))
    output_buf = IOBuffer()
    io = SplitIO(input_buf, output_buf)

    conn = PureHTTP2.HTTP2Connection()

    # No exception expected; transport EOF ends the loop cleanly
    # after the GOAWAY puts the connection into CLOSING state.
    PureHTTP2.serve_connection!(conn, io)

    @test conn.state in
          (PureHTTP2.ConnectionState.CLOSING, PureHTTP2.ConnectionState.CLOSED)

    # Inspect the server's response bytes: should contain at least a
    # server preface SETTINGS frame, a SETTINGS ACK (in response to
    # the client SETTINGS), and a PING ACK.
    response_bytes = take!(output_buf)
    @test length(response_bytes) > 0

    decoded = PureHTTP2.Frame[]
    pos = Ref(1)
    while pos[] <= length(response_bytes) - PureHTTP2.FRAME_HEADER_SIZE + 1
        frame, consumed = PureHTTP2.decode_frame(@view response_bytes[pos[]:end])
        push!(decoded, frame)
        pos[] += consumed
    end

    frame_types = [f.header.frame_type for f in decoded]
    @test PureHTTP2.FrameType.SETTINGS in frame_types

    settings_acks = count(f ->
        f.header.frame_type == PureHTTP2.FrameType.SETTINGS &&
        PureHTTP2.has_flag(f.header, PureHTTP2.FrameFlags.ACK), decoded)
    @test settings_acks >= 1

    ping_acks = count(f ->
        f.header.frame_type == PureHTTP2.FrameType.PING &&
        PureHTTP2.has_flag(f.header, PureHTTP2.FrameFlags.ACK), decoded)
    @test ping_acks == 1
end

@testitem "Transport: serve_connection! with Pipe" begin
    using PureHTTP2

    # Use paired Base.BufferStream instances as a Pipe-like
    # bidirectional transport. BufferStream blocks on read until data
    # arrives, exactly like a real socket, so this exercises the
    # blocking-read code path that IOBuffer does not.
    mutable struct PairedIO <: IO
        incoming::Base.BufferStream  # bytes the server reads (client→server)
        outgoing::Base.BufferStream  # bytes the server writes (server→client)
    end
    Base.read(io::PairedIO, n::Int) = read(io.incoming, n)
    Base.write(io::PairedIO, x::UInt8) = write(io.outgoing, x)
    Base.unsafe_write(io::PairedIO, p::Ptr{UInt8}, n::UInt) =
        unsafe_write(io.outgoing, p, n)
    Base.close(io::PairedIO) = (close(io.incoming); close(io.outgoing))

    client_to_server = Base.BufferStream()
    server_to_client = Base.BufferStream()

    server_io = PairedIO(client_to_server, server_to_client)
    conn = PureHTTP2.HTTP2Connection()

    server_err = Ref{Any}(nothing)
    server_task = @async try
        PureHTTP2.serve_connection!(conn, server_io)
    catch err
        server_err[] = err
        rethrow(err)
    end

    # Client side: write preface + SETTINGS + SETTINGS ACK + PING +
    # GOAWAY, then close the write side so serve_connection! sees EOF
    # and exits.
    write(client_to_server, PureHTTP2.CONNECTION_PREFACE)
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(Tuple{UInt16, UInt32}[])))
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.settings_frame(; ack=true)))
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.ping_frame(UInt8[9,8,7,6,5,4,3,2])))
    write(client_to_server, PureHTTP2.encode_frame(PureHTTP2.goaway_frame(0, PureHTTP2.ErrorCode.NO_ERROR)))
    close(client_to_server)

    # Wait for the server to finish. Should complete promptly on EOF.
    wait(server_task)

    @test server_err[] === nothing
    @test conn.state in
          (PureHTTP2.ConnectionState.CLOSING, PureHTTP2.ConnectionState.CLOSED)

    # Server should have written at least the preface SETTINGS and a
    # PING ACK. Drain server_to_client.
    close(server_to_client)
    response_bytes = read(server_to_client)
    @test length(response_bytes) >= PureHTTP2.FRAME_HEADER_SIZE
end

@testitem "Transport: ALPN helper stub (no extension)" begin
    using PureHTTP2

    # In the main env, OpenSSL.jl is NOT loaded, so the extension
    # does not load. The generic function must exist with zero
    # methods, and any call must throw MethodError.
    @test isempty(methods(PureHTTP2.set_alpn_h2!))
    @test :set_alpn_h2! in names(PureHTTP2)
    @test_throws MethodError PureHTTP2.set_alpn_h2!("dummy")
    @test_throws MethodError PureHTTP2.set_alpn_h2!(nothing, ["h2"])
end
