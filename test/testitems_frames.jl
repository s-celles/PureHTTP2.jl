@testitem "Frames: types enum" begin
    using HTTP2
    @test HTTP2.FrameType.DATA == 0x0
    @test HTTP2.FrameType.HEADERS == 0x1
    @test HTTP2.FrameType.PRIORITY == 0x2
    @test HTTP2.FrameType.RST_STREAM == 0x3
    @test HTTP2.FrameType.SETTINGS == 0x4
    @test HTTP2.FrameType.PUSH_PROMISE == 0x5
    @test HTTP2.FrameType.PING == 0x6
    @test HTTP2.FrameType.GOAWAY == 0x7
    @test HTTP2.FrameType.WINDOW_UPDATE == 0x8
    @test HTTP2.FrameType.CONTINUATION == 0x9
end

@testitem "Frames: flags enum" begin
    using HTTP2
    @test HTTP2.FrameFlags.END_STREAM == 0x1
    @test HTTP2.FrameFlags.END_HEADERS == 0x4
    @test HTTP2.FrameFlags.PADDED == 0x8
    @test HTTP2.FrameFlags.PRIORITY_FLAG == 0x20
    @test HTTP2.FrameFlags.ACK == 0x1
end

@testitem "Frames: error codes enum" begin
    using HTTP2
    @test HTTP2.ErrorCode.NO_ERROR == 0x0
    @test HTTP2.ErrorCode.PROTOCOL_ERROR == 0x1
    @test HTTP2.ErrorCode.INTERNAL_ERROR == 0x2
    @test HTTP2.ErrorCode.FLOW_CONTROL_ERROR == 0x3
    @test HTTP2.ErrorCode.SETTINGS_TIMEOUT == 0x4
    @test HTTP2.ErrorCode.STREAM_CLOSED == 0x5
    @test HTTP2.ErrorCode.FRAME_SIZE_ERROR == 0x6
    @test HTTP2.ErrorCode.REFUSED_STREAM == 0x7
    @test HTTP2.ErrorCode.CANCEL == 0x8
    @test HTTP2.ErrorCode.COMPRESSION_ERROR == 0x9
    @test HTTP2.ErrorCode.CONNECT_ERROR == 0xa
    @test HTTP2.ErrorCode.ENHANCE_YOUR_CALM == 0xb
    @test HTTP2.ErrorCode.INADEQUATE_SECURITY == 0xc
    @test HTTP2.ErrorCode.HTTP_1_1_REQUIRED == 0xd
end

@testitem "Frames: HTTP/2 constants" begin
    using HTTP2
    @test HTTP2.FRAME_HEADER_SIZE == 9
    @test HTTP2.DEFAULT_INITIAL_WINDOW_SIZE == 65535
    @test HTTP2.DEFAULT_MAX_FRAME_SIZE == 16384
    @test HTTP2.MIN_MAX_FRAME_SIZE == 16384
    @test HTTP2.MAX_MAX_FRAME_SIZE == 16777215  # 2^24 - 1
    @test HTTP2.DEFAULT_HEADER_TABLE_SIZE == 4096
end

@testitem "Frames: connection preface bytes" begin
    using HTTP2
    @test HTTP2.CONNECTION_PREFACE == b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
    @test length(HTTP2.CONNECTION_PREFACE) == 24
end

@testitem "Frames: header encoding" begin
    using HTTP2
    header = HTTP2.FrameHeader(100, HTTP2.FrameType.DATA, 0x01, 5)
    bytes = HTTP2.encode_frame_header(header)

    @test length(bytes) == 9

    # Length (24 bits, big-endian): 100 = 0x000064
    @test bytes[1] == 0x00
    @test bytes[2] == 0x00
    @test bytes[3] == 0x64

    # Type
    @test bytes[4] == HTTP2.FrameType.DATA

    # Flags
    @test bytes[5] == 0x01

    # Stream ID (31 bits, big-endian): 5 = 0x00000005
    @test bytes[6] == 0x00
    @test bytes[7] == 0x00
    @test bytes[8] == 0x00
    @test bytes[9] == 0x05
end

@testitem "Frames: header decoding" begin
    using HTTP2
    bytes = UInt8[
        0x00, 0x00, 0x64,  # Length: 100
        0x00,              # Type: DATA
        0x01,              # Flags: END_STREAM
        0x00, 0x00, 0x00, 0x05  # Stream ID: 5
    ]

    header = HTTP2.decode_frame_header(bytes)

    @test header.length == 100
    @test header.frame_type == HTTP2.FrameType.DATA
    @test header.flags == 0x01
    @test header.stream_id == 5
end

@testitem "Frames: header round-trip" begin
    using HTTP2
    original = HTTP2.FrameHeader(256, HTTP2.FrameType.HEADERS, 0x05, 1)
    encoded = HTTP2.encode_frame_header(original)
    decoded = HTTP2.decode_frame_header(encoded)

    @test decoded.length == original.length
    @test decoded.frame_type == original.frame_type
    @test decoded.flags == original.flags
    @test decoded.stream_id == original.stream_id
end

@testitem "Frames: PING handling" begin
    using HTTP2

    @testset "PING receives ACK with same payload" begin
        opaque_data = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        ping = HTTP2.ping_frame(opaque_data)

        @test ping.header.frame_type == HTTP2.FrameType.PING
        @test ping.header.stream_id == 0  # PING must be on stream 0
        @test ping.header.length == 8
        @test !HTTP2.has_flag(ping.header, HTTP2.FrameFlags.ACK)
        @test ping.payload == opaque_data

        ping_ack = HTTP2.ping_frame(opaque_data; ack=true)
        @test HTTP2.has_flag(ping_ack.header, HTTP2.FrameFlags.ACK)
        @test ping_ack.payload == opaque_data
    end

    @testset "PING payload must be exactly 8 bytes" begin
        @test_nowarn HTTP2.ping_frame(zeros(UInt8, 8))
        @test_throws ArgumentError HTTP2.ping_frame(zeros(UInt8, 7))
        @test_throws ArgumentError HTTP2.ping_frame(zeros(UInt8, 9))
    end

    @testset "PING on connection (stream 0)" begin
        conn = HTTP2.HTTP2Connection()
        conn.state = HTTP2.ConnectionState.OPEN

        opaque_data = UInt8[0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
        ping_frame = HTTP2.ping_frame(opaque_data)

        response_frames = HTTP2.process_ping_frame!(conn, ping_frame)

        @test length(response_frames) == 1
        ack_frame = response_frames[1]
        @test ack_frame.header.frame_type == HTTP2.FrameType.PING
        @test HTTP2.has_flag(ack_frame.header, HTTP2.FrameFlags.ACK)
        @test ack_frame.payload == opaque_data
    end
end

@testitem "Frames: GOAWAY handling" begin
    using HTTP2

    @testset "GOAWAY sent on graceful shutdown" begin
        conn = HTTP2.HTTP2Connection()
        conn.state = HTTP2.ConnectionState.OPEN
        conn.last_client_stream_id = UInt32(5)

        goaway = HTTP2.send_goaway(conn, HTTP2.ErrorCode.NO_ERROR)

        @test goaway.header.frame_type == HTTP2.FrameType.GOAWAY
        @test goaway.header.stream_id == 0
        @test conn.goaway_sent
        @test conn.state == HTTP2.ConnectionState.CLOSING

        last_stream_id, error_code, debug_data = HTTP2.parse_goaway_frame(goaway)
        @test last_stream_id == 5
        @test error_code == HTTP2.ErrorCode.NO_ERROR
    end

    @testset "GOAWAY with error closes connection" begin
        conn = HTTP2.HTTP2Connection()
        conn.state = HTTP2.ConnectionState.OPEN

        goaway = HTTP2.send_goaway(conn, HTTP2.ErrorCode.PROTOCOL_ERROR, Vector{UInt8}("protocol error"))

        @test conn.state == HTTP2.ConnectionState.CLOSED

        last_stream_id, error_code, debug_data = HTTP2.parse_goaway_frame(goaway)
        @test error_code == HTTP2.ErrorCode.PROTOCOL_ERROR
        @test String(debug_data) == "protocol error"
    end

    @testset "GOAWAY frame encoding" begin
        goaway = HTTP2.goaway_frame(10, HTTP2.ErrorCode.NO_ERROR, UInt8[])

        @test goaway.header.frame_type == HTTP2.FrameType.GOAWAY
        @test goaway.header.length == 8  # 4 bytes last-stream-id + 4 bytes error code

        payload = goaway.payload
        @test payload[1] == 0x00
        @test payload[2] == 0x00
        @test payload[3] == 0x00
        @test payload[4] == 0x0A
        @test payload[5] == 0x00
        @test payload[6] == 0x00
        @test payload[7] == 0x00
        @test payload[8] == 0x00
    end
end

@testitem "Frames: SETTINGS handling" begin
    using HTTP2

    @testset "SETTINGS parameters" begin
        @test HTTP2.SettingsParameter.HEADER_TABLE_SIZE == 0x1
        @test HTTP2.SettingsParameter.ENABLE_PUSH == 0x2
        @test HTTP2.SettingsParameter.MAX_CONCURRENT_STREAMS == 0x3
        @test HTTP2.SettingsParameter.INITIAL_WINDOW_SIZE == 0x4
        @test HTTP2.SettingsParameter.MAX_FRAME_SIZE == 0x5
        @test HTTP2.SettingsParameter.MAX_HEADER_LIST_SIZE == 0x6
    end

    @testset "SETTINGS frame encoding/decoding" begin
        settings = [
            (UInt16(HTTP2.SettingsParameter.MAX_CONCURRENT_STREAMS), UInt32(100)),
            (UInt16(HTTP2.SettingsParameter.INITIAL_WINDOW_SIZE), UInt32(65535)),
        ]

        frame = HTTP2.settings_frame(settings)
        @test frame.header.frame_type == HTTP2.FrameType.SETTINGS
        @test frame.header.stream_id == 0
        @test frame.header.length == 12  # 2 settings * 6 bytes each

        parsed = HTTP2.parse_settings_frame(frame)
        @test length(parsed) == 2
        @test parsed[1] == (UInt16(HTTP2.SettingsParameter.MAX_CONCURRENT_STREAMS), UInt32(100))
        @test parsed[2] == (UInt16(HTTP2.SettingsParameter.INITIAL_WINDOW_SIZE), UInt32(65535))
    end

    @testset "SETTINGS ACK" begin
        ack_frame = HTTP2.settings_frame(; ack=true)

        @test HTTP2.has_flag(ack_frame.header, HTTP2.FrameFlags.ACK)
        @test ack_frame.header.length == 0
    end
end

@testitem "Frames: WINDOW_UPDATE handling" begin
    using HTTP2

    @testset "WINDOW_UPDATE frame encoding" begin
        frame = HTTP2.window_update_frame(0, 65535)

        @test frame.header.frame_type == HTTP2.FrameType.WINDOW_UPDATE
        @test frame.header.length == 4
        @test frame.header.stream_id == 0

        increment = HTTP2.parse_window_update_frame(frame)
        @test increment == 65535
    end

    @testset "WINDOW_UPDATE on stream" begin
        frame = HTTP2.window_update_frame(5, 32768)

        @test frame.header.stream_id == 5

        increment = HTTP2.parse_window_update_frame(frame)
        @test increment == 32768
    end

    @testset "WINDOW_UPDATE increment validation" begin
        @test_nowarn HTTP2.window_update_frame(0, 1)
        @test_nowarn HTTP2.window_update_frame(0, 2147483647)  # 2^31 - 1

        @test_throws ArgumentError HTTP2.window_update_frame(0, 0)
    end
end

@testitem "Frames: RST_STREAM handling" begin
    using HTTP2
    frame = HTTP2.rst_stream_frame(5, HTTP2.ErrorCode.CANCEL)

    @test frame.header.frame_type == HTTP2.FrameType.RST_STREAM
    @test frame.header.stream_id == 5
    @test frame.header.length == 4

    # Error code: CANCEL = 0x08
    @test frame.payload[1] == 0x00
    @test frame.payload[2] == 0x00
    @test frame.payload[3] == 0x00
    @test frame.payload[4] == 0x08
end
