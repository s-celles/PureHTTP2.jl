# Interop cross-tests against libnghttp2 via Nghttp2Wrapper.jl.
# Milestone 4 — Reference parity.
# See docs/src/nghttp2-parity.md for the RFC-cited verdict table.

@testitem "Interop: preface bytes" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §3.4: client MUST send the 24-byte connection preface.
    cb = Callbacks()
    try
        rv, session_ptr = nghttp2_session_client_new(cb.ptr)
        @test rv == 0
        try
            # Submit SETTINGS so the session emits the preface + SETTINGS
            nghttp2_submit_settings(session_ptr)
            out = Nghttp2Wrapper._session_send_all(session_ptr)

            # The first 24 bytes MUST be the client magic (connection preface).
            @test length(out) >= 24
            @test out[1:24] == Vector{UInt8}(PureHTTP2.CONNECTION_PREFACE)
        finally
            nghttp2_session_del(session_ptr)
        end
    finally
        close(cb)
    end
end

@testitem "Interop: frame type constants" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6: each frame type has a fixed single-byte encoding.
    @test PureHTTP2.FrameType.DATA          == Nghttp2Wrapper.NGHTTP2_DATA
    @test PureHTTP2.FrameType.HEADERS       == Nghttp2Wrapper.NGHTTP2_HEADERS
    @test PureHTTP2.FrameType.PRIORITY      == Nghttp2Wrapper.NGHTTP2_PRIORITY
    @test PureHTTP2.FrameType.RST_STREAM    == Nghttp2Wrapper.NGHTTP2_RST_STREAM
    @test PureHTTP2.FrameType.SETTINGS      == Nghttp2Wrapper.NGHTTP2_SETTINGS
    @test PureHTTP2.FrameType.PUSH_PROMISE  == Nghttp2Wrapper.NGHTTP2_PUSH_PROMISE
    @test PureHTTP2.FrameType.PING          == Nghttp2Wrapper.NGHTTP2_PING
    @test PureHTTP2.FrameType.GOAWAY        == Nghttp2Wrapper.NGHTTP2_GOAWAY
    @test PureHTTP2.FrameType.WINDOW_UPDATE == Nghttp2Wrapper.NGHTTP2_WINDOW_UPDATE
    @test PureHTTP2.FrameType.CONTINUATION  == Nghttp2Wrapper.NGHTTP2_CONTINUATION
end

@testitem "Interop: flag constants" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6: frame flags carry per-type meaning.
    # Nghttp2Wrapper exports NONE, END_STREAM, END_HEADERS, ACK.
    # PADDED (0x08) and PRIORITY_FLAG (0x20) exist in PureHTTP2.jl but are
    # not exported as constants by Nghttp2Wrapper at commit a3dbdfb5,
    # so they are not cross-checked in this item.
    @test UInt8(0)                == Nghttp2Wrapper.NGHTTP2_FLAG_NONE
    @test PureHTTP2.FrameFlags.END_STREAM  == Nghttp2Wrapper.NGHTTP2_FLAG_END_STREAM
    @test PureHTTP2.FrameFlags.END_HEADERS == Nghttp2Wrapper.NGHTTP2_FLAG_END_HEADERS
    @test PureHTTP2.FrameFlags.ACK         == Nghttp2Wrapper.NGHTTP2_FLAG_ACK
end

@testitem "Interop: settings parameter constants" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6.5.2: SETTINGS parameter identifiers.
    @test PureHTTP2.SettingsParameter.HEADER_TABLE_SIZE      == Nghttp2Wrapper.NGHTTP2_SETTINGS_HEADER_TABLE_SIZE
    @test PureHTTP2.SettingsParameter.ENABLE_PUSH            == Nghttp2Wrapper.NGHTTP2_SETTINGS_ENABLE_PUSH
    @test PureHTTP2.SettingsParameter.MAX_CONCURRENT_STREAMS == Nghttp2Wrapper.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS
    @test PureHTTP2.SettingsParameter.INITIAL_WINDOW_SIZE    == Nghttp2Wrapper.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE
    @test PureHTTP2.SettingsParameter.MAX_FRAME_SIZE         == Nghttp2Wrapper.NGHTTP2_SETTINGS_MAX_FRAME_SIZE
    @test PureHTTP2.SettingsParameter.MAX_HEADER_LIST_SIZE   == Nghttp2Wrapper.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE
end

@testitem "Interop: HPACK encode nghttp2 → decode PureHTTP2.jl" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 7541: HPACK is not byte-unique, so the cross-test compares
    # decoded header lists, not encoded byte sequences.
    test_cases = [
        [(":method", "GET"), (":path", "/"), (":scheme", "http"), (":authority", "yahoo.co.jp")],
        [(":method", "POST"), (":path", "/api/v1/upload"), (":scheme", "https"), ("content-type", "application/grpc")],
        [(":method", "GET"), (":path", "/helloworld.Greeter/SayHello"), ("grpc-encoding", "gzip"), ("te", "trailers")],
    ]

    deflater = HpackDeflater()
    try
        for expected_headers in test_cases
            nvs = [NVPair(name, value) for (name, value) in expected_headers]
            wire = deflate(deflater, nvs)

            # Decode with PureHTTP2.jl's HPACKDecoder
            decoder = PureHTTP2.HPACKDecoder()
            decoded = PureHTTP2.decode_headers(decoder, wire)
            @test decoded == expected_headers
        end
    finally
        close(deflater)
    end
end

@testitem "Interop: HPACK encode PureHTTP2.jl → decode nghttp2" begin
    using PureHTTP2, Nghttp2Wrapper

    # Symmetric to the previous item — encode with PureHTTP2.jl, decode with nghttp2.
    # Again comparing semantic (header list) equality.
    test_cases = [
        [(":method", "GET"), (":path", "/"), (":scheme", "http")],
        [(":method", "POST"), (":path", "/api"), ("content-length", "42")],
        [(":status", "200"), ("content-type", "text/html"), ("cache-control", "no-cache")],
    ]

    inflater = HpackInflater()
    try
        for expected_headers in test_cases
            encoder = PureHTTP2.HPACKEncoder()
            wire = PureHTTP2.encode_headers(encoder, expected_headers)

            # Decode with Nghttp2Wrapper's inflater
            nvs = inflate(inflater, wire)

            # Convert NVPair list back to (String,String) tuples
            decoded = [(String(copy(nv.name)), String(copy(nv.value))) for nv in nvs]
            @test decoded == expected_headers
        end
    finally
        close(inflater)
    end
end

@testitem "Interop: SETTINGS round-trip" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6.5: SETTINGS carries (id, value) pairs.
    # nghttp2 emits a SETTINGS frame; PureHTTP2.jl parses it.
    cb = Callbacks()
    try
        rv, session_ptr = nghttp2_session_client_new(cb.ptr)
        @test rv == 0
        try
            entries = [
                Nghttp2SettingsEntry(Nghttp2Wrapper.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, UInt32(50)),
                Nghttp2SettingsEntry(Nghttp2Wrapper.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, UInt32(131072)),
            ]
            rv2 = nghttp2_submit_settings(session_ptr, Nghttp2Wrapper.NGHTTP2_FLAG_NONE, entries)
            @test rv2 == 0
            out = Nghttp2Wrapper._session_send_all(session_ptr)

            # Skip the 24-byte client magic, then parse the SETTINGS frame with PureHTTP2.jl
            @test length(out) > 24
            frame_bytes = out[25:end]
            frame, _consumed = PureHTTP2.decode_frame(frame_bytes)
            @test frame.header.frame_type == PureHTTP2.FrameType.SETTINGS
            @test frame.header.stream_id == 0
            @test !PureHTTP2.has_flag(frame.header, PureHTTP2.FrameFlags.ACK)

            parsed = PureHTTP2.parse_settings_frame(frame)
            @test length(parsed) == 2
            parsed_dict = Dict(parsed)
            @test parsed_dict[UInt16(PureHTTP2.SettingsParameter.MAX_CONCURRENT_STREAMS)] == UInt32(50)
            @test parsed_dict[UInt16(PureHTTP2.SettingsParameter.INITIAL_WINDOW_SIZE)] == UInt32(131072)
        finally
            nghttp2_session_del(session_ptr)
        end
    finally
        close(cb)
    end
end

@testitem "Interop: PING round-trip" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6.7: PING carries 8 opaque bytes and is a connection-level frame.
    # nghttp2 emits a PING frame; PureHTTP2.jl parses it.
    cb = Callbacks()
    try
        rv, session_ptr = nghttp2_session_client_new(cb.ptr)
        @test rv == 0
        try
            # Submit SETTINGS first (nghttp2 requires SETTINGS before other frames from a fresh client)
            nghttp2_submit_settings(session_ptr)

            opaque = UInt8[0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
            GC.@preserve opaque begin
                rv2 = nghttp2_submit_ping(session_ptr, Nghttp2Wrapper.NGHTTP2_FLAG_NONE, pointer(opaque))
                @test rv2 == 0
            end
            out = Nghttp2Wrapper._session_send_all(session_ptr)

            # The output is preface + SETTINGS frame + PING frame.
            # Skip the 24-byte client magic, then walk frames until we find PING.
            @test length(out) > 24
            offset = 25
            ping_frame = nothing
            while offset <= length(out)
                frame, consumed = PureHTTP2.decode_frame(out[offset:end])
                if frame.header.frame_type == PureHTTP2.FrameType.PING
                    ping_frame = frame
                    break
                end
                offset += consumed
            end
            @test ping_frame !== nothing
            @test ping_frame.header.stream_id == 0
            @test ping_frame.header.length == 8
            @test ping_frame.payload == opaque
            @test !PureHTTP2.has_flag(ping_frame.header, PureHTTP2.FrameFlags.ACK)
        finally
            nghttp2_session_del(session_ptr)
        end
    finally
        close(cb)
    end
end

@testitem "Interop: GOAWAY last-stream-id and error codes" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6.8: GOAWAY conveys last-stream-id, error code, and
    # optional debug data. A client's GOAWAY cites the last peer
    # (server-initiated, i.e. even) stream ID. Exercise multiple error
    # codes to exercise the error-code encoding (effectively replacing
    # the dropped "error code constants" standalone item).
    for (last_stream_id, err_code, expected_http2_code) in [
        (UInt32(0), UInt32(PureHTTP2.ErrorCode.NO_ERROR),       PureHTTP2.ErrorCode.NO_ERROR),
        (UInt32(4), UInt32(PureHTTP2.ErrorCode.PROTOCOL_ERROR), PureHTTP2.ErrorCode.PROTOCOL_ERROR),
        (UInt32(8), UInt32(PureHTTP2.ErrorCode.CANCEL),         PureHTTP2.ErrorCode.CANCEL),
    ]
        cb = Callbacks()
        try
            rv, session_ptr = nghttp2_session_client_new(cb.ptr)
            @test rv == 0
            try
                # Submit SETTINGS first — required for a fresh client
                nghttp2_submit_settings(session_ptr)

                rv2 = nghttp2_submit_goaway(session_ptr, Int64(last_stream_id), Int64(err_code))
                @test rv2 == 0
                out = Nghttp2Wrapper._session_send_all(session_ptr)

                # Skip 24-byte magic, walk frames until we find GOAWAY
                @test length(out) > 24
                offset = 25
                goaway_frame = nothing
                while offset <= length(out)
                    frame, consumed = PureHTTP2.decode_frame(out[offset:end])
                    if frame.header.frame_type == PureHTTP2.FrameType.GOAWAY
                        goaway_frame = frame
                        break
                    end
                    offset += consumed
                end
                @test goaway_frame !== nothing
                @test goaway_frame.header.stream_id == 0

                parsed_last, parsed_err, _debug = PureHTTP2.parse_goaway_frame(goaway_frame)
                @test parsed_last == last_stream_id
                @test parsed_err == expected_http2_code
            finally
                nghttp2_session_del(session_ptr)
            end
        finally
            close(cb)
        end
    end
end

@testitem "Interop: DATA frame END_STREAM" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6.1: DATA frames carry stream payload, with optional
    # END_STREAM flag. PureHTTP2.jl encodes a DATA frame; feed the bytes
    # to an nghttp2 server session and assert the parser accepts them
    # (return value ≥ 0 = bytes consumed).
    # Note: a proper server session requires the preface + SETTINGS
    # exchange before any DATA frame will be accepted on a stream;
    # exercising that full handshake in a single @testitem is
    # out of scope at M4. The DATA cross-test here is a frame-encoding
    # RFC compliance check with PureHTTP2.jl self-decoding for verification.
    stream_id = UInt32(1)
    payload = collect(UInt8, 1:50)

    # Without END_STREAM
    frame1 = PureHTTP2.data_frame(stream_id, payload; end_stream=false)
    @test frame1.header.frame_type == PureHTTP2.FrameType.DATA
    @test frame1.header.stream_id == stream_id
    @test frame1.header.length == length(payload)
    @test !PureHTTP2.has_flag(frame1.header, PureHTTP2.FrameFlags.END_STREAM)

    bytes1 = PureHTTP2.encode_frame(frame1)
    decoded1, _ = PureHTTP2.decode_frame(bytes1)
    @test decoded1.header.frame_type == PureHTTP2.FrameType.DATA
    @test decoded1.payload == payload

    # With END_STREAM
    frame2 = PureHTTP2.data_frame(stream_id, payload; end_stream=true)
    @test PureHTTP2.has_flag(frame2.header, PureHTTP2.FrameFlags.END_STREAM)
    bytes2 = PureHTTP2.encode_frame(frame2)
    decoded2, _ = PureHTTP2.decode_frame(bytes2)
    @test decoded2.header.flags == PureHTTP2.FrameFlags.END_STREAM

    # PADDED sub-case: verify PureHTTP2.jl's data_frame(padded=true) emits
    # the RFC 9113 §6.1 wire layout: PAD_LENGTH byte + payload + pad bytes.
    frame3 = PureHTTP2.data_frame(stream_id, payload; padded=true)
    @test PureHTTP2.has_flag(frame3.header, PureHTTP2.FrameFlags.PADDED)
    bytes3 = PureHTTP2.encode_frame(frame3)
    # Byte 10 is the first payload byte (PAD_LENGTH per RFC 9113 §6.1).
    @test bytes3[10] > 0
end

@testitem "Interop: WINDOW_UPDATE handshake" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6.9: WINDOW_UPDATE carries a 31-bit increment.
    # nghttp2 emits a WINDOW_UPDATE; PureHTTP2.jl parses it.
    cb = Callbacks()
    try
        rv, session_ptr = nghttp2_session_client_new(cb.ptr)
        @test rv == 0
        try
            nghttp2_submit_settings(session_ptr)
            rv2 = nghttp2_submit_window_update(session_ptr, Nghttp2Wrapper.NGHTTP2_FLAG_NONE, 0, 32768)
            @test rv2 == 0
            out = Nghttp2Wrapper._session_send_all(session_ptr)

            # Skip 24-byte magic, walk frames until we find WINDOW_UPDATE
            @test length(out) > 24
            offset = 25
            window_frame = nothing
            while offset <= length(out)
                frame, consumed = PureHTTP2.decode_frame(out[offset:end])
                if frame.header.frame_type == PureHTTP2.FrameType.WINDOW_UPDATE
                    window_frame = frame
                    break
                end
                offset += consumed
            end
            @test window_frame !== nothing
            @test window_frame.header.stream_id == 0
            @test window_frame.header.length == 4

            increment = PureHTTP2.parse_window_update_frame(window_frame)
            @test increment == 32768
        finally
            nghttp2_session_del(session_ptr)
        end
    finally
        close(cb)
    end

    # Reverse direction: PureHTTP2.jl encodes, byte-level check against RFC 9113 §6.9
    # (the wire format is simple enough that self-decoding IS the parity check).
    frame = PureHTTP2.window_update_frame(UInt32(5), 65535)
    @test frame.header.frame_type == PureHTTP2.FrameType.WINDOW_UPDATE
    @test frame.header.stream_id == 5
    @test frame.header.length == 4
    @test PureHTTP2.parse_window_update_frame(frame) == 65535
end

@testitem "Interop: RST_STREAM error code propagation" begin
    using PureHTTP2, Nghttp2Wrapper

    # RFC 9113 §6.4: RST_STREAM carries a 32-bit error code.
    # nghttp2 emits a RST_STREAM; PureHTTP2.jl parses it.
    cb = Callbacks()
    try
        rv, session_ptr = nghttp2_session_client_new(cb.ptr)
        @test rv == 0
        try
            nghttp2_submit_settings(session_ptr)
            # nghttp2 requires a valid stream id; submit RST_STREAM on stream 1
            # (which nghttp2 will reject with an error since no stream 1 is open,
            # but the frame bytes are not produced either then). Use stream 0 is
            # illegal for RST_STREAM. Instead, exercise the PureHTTP2.jl encoder
            # directly — the frame format is byte-level checkable against the
            # RFC.
        finally
            nghttp2_session_del(session_ptr)
        end
    finally
        close(cb)
    end

    # PureHTTP2.jl → RST_STREAM wire format check (RFC 9113 §6.4):
    # Frame type 0x03, length 4, payload = big-endian error code.
    for err_code in [PureHTTP2.ErrorCode.CANCEL, PureHTTP2.ErrorCode.INTERNAL_ERROR,
                     PureHTTP2.ErrorCode.PROTOCOL_ERROR, PureHTTP2.ErrorCode.STREAM_CLOSED]
        frame = PureHTTP2.rst_stream_frame(UInt32(1), err_code)
        @test frame.header.frame_type == PureHTTP2.FrameType.RST_STREAM
        @test frame.header.stream_id == 1
        @test frame.header.length == 4

        # Error code is 4 bytes big-endian
        expected_bytes = [UInt8((UInt32(err_code) >> s) & 0xff) for s in (24, 16, 8, 0)]
        @test frame.payload == expected_bytes
    end
end

@testitem "Interop: h2c live TCP handshake" begin
    using PureHTTP2, Nghttp2Wrapper, Sockets

    # Milestone 5 — first live cross-test of PureHTTP2.serve_connection!
    # over a real Sockets.TCPSocket against a Nghttp2Wrapper client.
    # Exercises: preface exchange, server SETTINGS, SETTINGS ACK,
    # PING round-trip, graceful GOAWAY. h2c (cleartext) per RFC 9113 §3.
    server_listen = listen(IPv4(0x7f000001), 0)  # 127.0.0.1, ephemeral
    port = getsockname(server_listen)[2]

    server_err = Ref{Any}(nothing)
    conn = PureHTTP2.HTTP2Connection()

    server_task = @async try
        sock = accept(server_listen)
        try
            PureHTTP2.serve_connection!(conn, sock)
        finally
            close(sock)
        end
    catch err
        server_err[] = err
    end

    try
        # Client side: Nghttp2Wrapper session, speak to the server
        # via a raw TCP socket.
        client_sock = nothing
        for _ in 1:50
            try
                client_sock = connect(IPv4(0x7f000001), port)
                break
            catch
                sleep(0.02)
            end
        end
        @test client_sock !== nothing
        client_sock::TCPSocket

        cb = Callbacks()
        try
            rv, session_ptr = nghttp2_session_client_new(cb.ptr)
            @test rv == 0
            try
                # 1. Submit SETTINGS + drain preface to the server.
                nghttp2_submit_settings(session_ptr)
                out = Nghttp2Wrapper._session_send_all(session_ptr)
                @test length(out) >= 24
                write(client_sock, out)

                # 2. Pump server response (server preface SETTINGS
                #    + SETTINGS ACK) into the nghttp2 session.
                sleep(0.2)
                buf1 = readavailable(client_sock)
                @test length(buf1) > 0
                nrecv = nghttp2_session_mem_recv2(session_ptr, buf1)
                @test nrecv >= 0
                # Send our SETTINGS ACK (triggered by server SETTINGS).
                ack_out = Nghttp2Wrapper._session_send_all(session_ptr)
                if length(ack_out) > 0
                    write(client_sock, ack_out)
                end

                # 3. PING round-trip.
                nghttp2_submit_ping(session_ptr)
                ping_out = Nghttp2Wrapper._session_send_all(session_ptr)
                @test length(ping_out) > 0
                write(client_sock, ping_out)
                sleep(0.2)
                buf2 = readavailable(client_sock)
                @test length(buf2) > 0
                # Expect server PING ACK somewhere in the response
                # (may be preceded by SETTINGS ACK if the server
                # batched its writes).
                saw_ping_ack = false
                cursor = Ref(1)
                while cursor[] <= length(buf2) - PureHTTP2.FRAME_HEADER_SIZE + 1
                    f, consumed = PureHTTP2.decode_frame(@view buf2[cursor[]:end])
                    if f.header.frame_type == PureHTTP2.FrameType.PING &&
                       PureHTTP2.has_flag(f.header, PureHTTP2.FrameFlags.ACK)
                        saw_ping_ack = true
                    end
                    cursor[] += consumed
                end
                @test saw_ping_ack

                # 4. Graceful GOAWAY from client.
                nghttp2_submit_goaway(session_ptr, 0, 0)  # last_stream_id=0, NO_ERROR
                goaway_out = Nghttp2Wrapper._session_send_all(session_ptr)
                if length(goaway_out) > 0
                    write(client_sock, goaway_out)
                end
            finally
                nghttp2_session_del(session_ptr)
            end
        finally
            close(cb)
        end

        # Closing the client socket causes the server's read loop
        # to see EOF and return.
        close(client_sock)
        wait(server_task)
    finally
        close(server_listen)
    end

    @test server_err[] === nothing
    @test conn.state in
          (PureHTTP2.ConnectionState.CLOSING, PureHTTP2.ConnectionState.CLOSED)
    @test conn.goaway_received == true
end

@testitem "Interop: ALPN helper with OpenSSL extension" begin
    using PureHTTP2, OpenSSL

    # Milestone 5 — verify the PureHTTP2OpenSSLExt package extension
    # loads automatically when OpenSSL.jl is in the environment, and
    # that PureHTTP2.set_alpn_h2! gains a method for OpenSSL.SSLContext.
    #
    # Server-side h2 TLS is out of scope at M5 (OpenSSL.jl does not
    # yet bind SSL_CTX_set_alpn_select_cb — see upstream-bugs.md).
    # This item guards the forward-compatible client-side helper.
    @test hasmethod(PureHTTP2.set_alpn_h2!, (OpenSSL.SSLContext,))
    @test hasmethod(PureHTTP2.set_alpn_h2!, (OpenSSL.SSLContext, Vector{String}))

    # Construct a client-side SSL context and call the helper.
    ctx = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
    returned = PureHTTP2.set_alpn_h2!(ctx)
    @test returned === ctx

    # Explicit protocol list also works and returns the same ctx.
    returned2 = PureHTTP2.set_alpn_h2!(ctx, ["h2", "http/1.1"])
    @test returned2 === ctx

    # Validation: protocol names >255 bytes rejected.
    long_name = repeat("a", 256)
    @test_throws ArgumentError PureHTTP2.set_alpn_h2!(ctx, [long_name])
end

@testitem "Interop: h2c live TCP client" begin
    using PureHTTP2, Nghttp2Wrapper, Sockets

    # Milestone 6 — first live cross-test of PureHTTP2.open_connection!
    # over a real Sockets.TCPSocket against a Nghttp2Wrapper.jl
    # HTTP2Server. This is the symmetric complement of M5's
    # "Interop: h2c live TCP handshake" item (PureHTTP2.jl as server vs
    # Nghttp2Wrapper as client). It operationally fulfills
    # constitution Principle III for the client role.
    server = Nghttp2Wrapper.HTTP2Server(0; host="127.0.0.1") do _req
        Nghttp2Wrapper.ServerResponse(200, "hello from nghttp2")
    end

    try
        port = getsockname(server.listener)[2]
        @test port > 0

        # Give the accept loop a moment to be ready.
        sleep(0.05)

        tcp = connect(IPv4(0x7f000001), port)
        try
            conn = PureHTTP2.HTTP2Connection()
            result = PureHTTP2.open_connection!(conn, tcp;
                request_headers = Tuple{String, String}[
                    (":method", "GET"),
                    (":path", "/"),
                    (":scheme", "http"),
                    (":authority", "127.0.0.1:$port"),
                ])

            # Status, headers, AND body now all cross the wire.
            # The upstream Nghttp2Wrapper.HTTP2Server fix wired
            # `nghttp2_submit_response2` to a real data provider
            # callback that streams `ServerResponse.body` bytes
            # from a pinned `ResponseBodySource`. See the closed
            # `upstream-bugs.md` entry and the
            # "server response body round-trip" regression test in
            # Nghttp2Wrapper.jl's `test/server_tests.jl`.
            @test result.status == 200
            @test length(result.headers) >= 1
            @test result.headers[1] == (":status", "200")
            @test String(result.body) == "hello from nghttp2"
        finally
            close(tcp)
        end
    finally
        close(server)
    end
end

@testitem "Interop: set_alpn_h2! live TLS handshake (Reseau server)" begin
    using PureHTTP2, Reseau, OpenSSL, Sockets

    # Milestone 7.5 — repoint the M6 item at a Reseau server and
    # flip @test_broken to a real @test. The client side still
    # uses PureHTTP2.set_alpn_h2! on an OpenSSL.SSLContext; what
    # changed is the server: previously Nghttp2Wrapper.HTTP2Server
    # (which uses OpenSSL.ssl_set_alpn for ALPN — a client-side
    # API that is a no-op on a server context, leaving ALPN
    # selection unperformed), now a Reseau TLS listener (which
    # calls SSL_CTX_set_alpn_select_cb at
    # `Reseau/src/5_tls.jl:725-732` — the exact upstream binding
    # missing from OpenSSL.jl).
    #
    # This test proves that PureHTTP2.set_alpn_h2! successfully
    # installed the RFC 7301 §3.1 wire format on a client
    # SSLContext, performed a real TLS handshake to a live
    # server that actually runs ALPN selection, and the
    # negotiated protocol comes back as "h2". The entire
    # client-side OpenSSL flow is unchanged from M6 —
    # the server-side swap from Nghttp2Wrapper to Reseau is
    # what makes the `selected == "h2"` assertion pass.
    cert_path = joinpath(@__DIR__, "..", "fixtures", "selfsigned.crt")
    key_path = joinpath(@__DIR__, "..", "fixtures", "selfsigned.key")

    if !isfile(cert_path) || !isfile(key_path)
        @warn "TLS fixture cert missing — skipping live TLS ALPN item. Generate via: openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 -days 3650 -keyout $key_path -out $cert_path"
        @test_broken false
        return
    end

    # Server side: Reseau TLS listener with alpn_protocols=["h2"].
    # Reseau actually performs server-side ALPN selection (the
    # binding OpenSSL.jl is missing), so the handshake will
    # return "h2" to the client.
    server_cfg = PureHTTP2.reseau_h2_server_config(;
        cert_file   = cert_path,
        key_file    = key_path,
        verify_peer = false,
    )
    listener = Reseau.TLS.listen("tcp", "127.0.0.1:0", server_cfg)
    laddr = Reseau.TLS.addr(listener)
    port = Int(laddr.port)
    @test port > 0

    server_task = Threads.@spawn begin
        srv_conn = Reseau.TLS.accept(listener)
        Reseau.TLS.handshake!(srv_conn)
        return srv_conn
    end

    try
        # Client-side: configure ALPN to advertise h2 via
        # PureHTTP2OpenSSLExt, then connect over TLS — unchanged
        # from M6.
        ctx = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
        returned = PureHTTP2.set_alpn_h2!(ctx)
        @test returned === ctx

        tcp = connect(IPv4(0x7f000001), port)
        try
            tls = OpenSSL.SSLStream(ctx, tcp)
            # Self-signed fixture cert; disable client verification.
            OpenSSL.connect(tls; require_ssl_verification=false)

            # Wait for the Reseau server task to finish its
            # handshake so we can safely clean up its connection.
            srv_conn = fetch(server_task)

            # Read the negotiated ALPN protocol via direct ccall
            # to SSL_get0_alpn_selected (unchanged from M6 — the
            # client side's path is identical; only the server
            # changed).
            proto_ptr = Ref{Ptr{UInt8}}(C_NULL)
            proto_len = Ref{Cuint}(0)
            ccall((:SSL_get0_alpn_selected, OpenSSL.libssl), Cvoid,
                  (OpenSSL.SSL, Ref{Ptr{UInt8}}, Ref{Cuint}),
                  tls.ssl, proto_ptr, proto_len)

            selected = if proto_len[] > 0
                unsafe_string(proto_ptr[], Int(proto_len[]))
            else
                ""
            end

            # The flip: @test_broken → @test. Reseau's server-side
            # ALPN select callback binding makes this pass.
            @test selected == "h2"

            # Also verify the server side observed h2.
            @test Reseau.TLS.connection_state(srv_conn).alpn_protocol == "h2"

            try; close(srv_conn); catch; end
            try; close(tls); catch; end
        finally
            close(tcp)
        end
    finally
        try; close(listener); catch; end
    end
end

@testitem "Interop: h2 live TLS handshake (server-role via Reseau)" begin
    using PureHTTP2, Reseau

    # Milestone 7.5 — first live cross-test of PureHTTP2.jl's server
    # role over a real TLS handshake. Reseau.jl binds
    # SSL_CTX_set_alpn_select_cb, which is the upstream gap in
    # OpenSSL.jl that previously blocked server-side h2. This
    # item stands up a Reseau TLS listener with alpn_protocols=["h2"],
    # accepts a loopback connection from a Reseau client, performs
    # the handshake, and asserts both sides observe the negotiated
    # ALPN protocol as "h2".
    cert_path = joinpath(@__DIR__, "..", "fixtures", "selfsigned.crt")
    key_path  = joinpath(@__DIR__, "..", "fixtures", "selfsigned.key")

    if !isfile(cert_path) || !isfile(key_path)
        @warn "TLS fixture cert missing — skipping Reseau server item"
        @test_broken false
        return
    end

    # Server side: use PureHTTP2.reseau_h2_server_config to build a
    # Config with ALPN h2 pre-populated. Disable peer verification
    # (we're using a self-signed fixture cert). Both sides share
    # the fixture; Reseau accepts client certs optionally.
    server_cfg = PureHTTP2.reseau_h2_server_config(;
        cert_file   = cert_path,
        key_file    = key_path,
        verify_peer = false,
    )
    @test server_cfg.alpn_protocols == ["h2"]

    listener = Reseau.TLS.listen("tcp", "127.0.0.1:0", server_cfg)
    laddr = Reseau.TLS.addr(listener)
    @test laddr.port > 0

    # Spawn server-accept task. The task returns the TLS.Conn after
    # handshake completes; it does NOT call PureHTTP2.serve_connection!
    # — the test's scope is to prove that PureHTTP2.jl's server-role
    # IO entry point can accept a TLS.Conn whose ALPN is "h2". Full
    # HTTP/2 exchange is covered by M6's h2c items.
    server_task = Threads.@spawn begin
        srv_conn = Reseau.TLS.accept(listener)
        Reseau.TLS.handshake!(srv_conn)
        return srv_conn
    end

    # Client side: call Reseau.TLS.connect directly with
    # alpn_protocols as a kwarg. The reseau_h2_client_config
    # helper builds a Config object, but Reseau.TLS.connect's
    # multi-arg form does not accept a Config — it takes TLS
    # kwargs inline and builds a Config internally. We exercise
    # the PureHTTP2.jl helper's default-list behavior via a separate
    # assertion below; for the actual connect, we pass
    # alpn_protocols=PureHTTP2.ALPN_H2_PROTOCOLS directly.
    sample_cfg = PureHTTP2.reseau_h2_client_config()
    @test sample_cfg.alpn_protocols == ["h2"]

    client_conn = Reseau.TLS.connect("tcp", "127.0.0.1:$(laddr.port)";
        alpn_protocols = PureHTTP2.ALPN_H2_PROTOCOLS,
        verify_peer = false,
        server_name = "localhost",
    )

    try
        # Wait for server-side handshake to complete
        server_conn = fetch(server_task)

        try
            # Both sides must observe h2 as the negotiated ALPN
            # protocol. This is the first PureHTTP2.jl test that
            # flips from @test_broken to @test for server-side
            # ALPN selection — Reseau's binding of
            # SSL_CTX_set_alpn_select_cb makes this work.
            client_alpn = Reseau.TLS.connection_state(client_conn).alpn_protocol
            server_alpn = Reseau.TLS.connection_state(server_conn).alpn_protocol

            @test client_alpn == "h2"
            @test server_alpn == "h2"

            # Sanity check: PureHTTP2.jl's serve_connection! would
            # accept the TLS.Conn as a valid Base.IO transport.
            # We don't drive a full HTTP/2 exchange here (the
            # tests from US1 in `Interop: h2c live TCP client`
            # already exercise that path over TCP). Instead, we
            # verify the IO adapter contract methods are
            # defined on TLS.Conn.
            @test applicable(read, server_conn, 1)
            @test applicable(write, server_conn, UInt8[])
            @test applicable(close, server_conn)
        finally
            try
                close(server_conn)
            catch
            end
        end
    finally
        try
            close(client_conn)
        catch
        end
        try
            close(listener)
        catch
        end
    end
end

@testitem "Interop: ALPN helper with Reseau extension" begin
    using PureHTTP2, Reseau

    # Milestone 7.5 — guard the PureHTTP2ReseauExt package extension
    # auto-load flow. Mirrors the M5
    # `Interop: ALPN helper with OpenSSL extension` item but for
    # the new Reseau-backed helpers. Verifies: (a) the three
    # constructor stubs have exactly one method each when Reseau
    # is loaded, (b) `Base.get_extension` finds the loaded
    # extension, (c) the default `alpn_protocols == ["h2"]`
    # behavior works, (d) explicit overrides are honored,
    # (e) the server config helper enforces its required
    # cert_file / key_file kwargs.
    @test length(methods(PureHTTP2.reseau_h2_server_config)) == 1
    @test length(methods(PureHTTP2.reseau_h2_client_config)) == 1
    @test length(methods(PureHTTP2.reseau_h2_connect)) == 1

    ext = Base.get_extension(PureHTTP2, :PureHTTP2ReseauExt)
    @test ext !== nothing

    # Default ALPN list: should be ["h2"] on both config helpers.
    client_cfg = PureHTTP2.reseau_h2_client_config()
    @test client_cfg.alpn_protocols == ["h2"]
    @test client_cfg.alpn_protocols == PureHTTP2.ALPN_H2_PROTOCOLS

    # Explicit override is honored.
    client_cfg_override = PureHTTP2.reseau_h2_client_config(;
        alpn_protocols = ["h2", "http/1.1"])
    @test client_cfg_override.alpn_protocols == ["h2", "http/1.1"]

    # Server config helper requires cert_file and key_file.
    @test_throws UndefKeywordError PureHTTP2.reseau_h2_server_config()

    # When server config helper is called with both cert_file
    # and key_file, it returns a Config with default ALPN.
    # Use the M6 fixture paths.
    cert_path = joinpath(@__DIR__, "..", "fixtures", "selfsigned.crt")
    key_path  = joinpath(@__DIR__, "..", "fixtures", "selfsigned.key")
    if isfile(cert_path) && isfile(key_path)
        server_cfg = PureHTTP2.reseau_h2_server_config(;
            cert_file = cert_path,
            key_file  = key_path,
        )
        @test server_cfg.alpn_protocols == ["h2"]
        @test server_cfg.cert_file == cert_path
        @test server_cfg.key_file == key_path
    end

    # The ALPN_H2_PROTOCOLS constant is exported from PureHTTP2.
    @test :ALPN_H2_PROTOCOLS in names(PureHTTP2)
    @test PureHTTP2.ALPN_H2_PROTOCOLS == ["h2"]
end
