# AC6: Connection Management Tests
# Tests per RFC 7540 and gRPC HTTP/2 Protocol Specification

using Test
using HTTP2

@testset "AC6: Connection Management" begin

    # =========================================================================
    # T037: Connection Preface
    # =========================================================================

    @testset "T037: Connection preface" begin

        @testset "Connection preface constant" begin
            @test HTTP2.CONNECTION_PREFACE == b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
            @test length(HTTP2.CONNECTION_PREFACE) == 24
        end

        @testset "Connection starts in PREFACE state" begin
            conn = HTTP2.HTTP2Connection()
            @test conn.state == HTTP2.ConnectionState.PREFACE
        end

        @testset "Valid preface transitions to OPEN" begin
            conn = HTTP2.HTTP2Connection()
            preface = Vector{UInt8}(HTTP2.CONNECTION_PREFACE)
            success, frames = HTTP2.process_preface(conn, preface)

            @test success
            @test conn.state == HTTP2.ConnectionState.OPEN
        end

        @testset "Invalid preface throws error" begin
            conn = HTTP2.HTTP2Connection()
            # Same length but wrong content
            invalid = Vector{UInt8}("PRI * HTTP/1.1\r\n\r\nSM\r\n\r\n")
            @test_throws HTTP2.ConnectionError HTTP2.process_preface(conn, invalid)
        end

        @testset "Short preface returns false (needs more data)" begin
            conn = HTTP2.HTTP2Connection()
            short = Vector{UInt8}("PRI * HTTP")
            success, _ = HTTP2.process_preface(conn, short)
            @test !success
            @test conn.state == HTTP2.ConnectionState.PREFACE
        end

    end  # T037

    # =========================================================================
    # T038: PING Frame Handling
    # =========================================================================

    @testset "T038: PING frame handling" begin

        @testset "PING frame on stream 0" begin
            ping = HTTP2.ping_frame(zeros(UInt8, 8))
            @test ping.header.stream_id == 0
        end

        @testset "PING payload is 8 bytes" begin
            ping = HTTP2.ping_frame(UInt8[1,2,3,4,5,6,7,8])
            @test ping.header.length == 8
        end

        @testset "PING ACK has same payload" begin
            opaque_data = UInt8[0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
            conn = HTTP2.HTTP2Connection()
            conn.state = HTTP2.ConnectionState.OPEN

            ping = HTTP2.ping_frame(opaque_data)
            responses = HTTP2.process_ping_frame!(conn, ping)

            @test length(responses) == 1
            ack = responses[1]
            @test HTTP2.has_flag(ack.header, HTTP2.FrameFlags.ACK)
            @test ack.payload == opaque_data
        end

        @testset "PING ACK is not re-acknowledged" begin
            conn = HTTP2.HTTP2Connection()
            conn.state = HTTP2.ConnectionState.OPEN

            ping_ack = HTTP2.ping_frame(zeros(UInt8, 8); ack=true)
            responses = HTTP2.process_ping_frame!(conn, ping_ack)

            @test isempty(responses)
        end

    end  # T038

    # =========================================================================
    # T039: GOAWAY Frame Handling
    # =========================================================================

    @testset "T039: GOAWAY frame handling" begin

        @testset "GOAWAY on stream 0" begin
            goaway = HTTP2.goaway_frame(10, HTTP2.ErrorCode.NO_ERROR)
            @test goaway.header.stream_id == 0
        end

        @testset "GOAWAY with NO_ERROR → CLOSING" begin
            conn = HTTP2.HTTP2Connection()
            conn.state = HTTP2.ConnectionState.OPEN
            conn.last_client_stream_id = UInt32(5)

            HTTP2.send_goaway(conn, HTTP2.ErrorCode.NO_ERROR)

            @test conn.goaway_sent
            @test conn.state == HTTP2.ConnectionState.CLOSING
        end

        @testset "GOAWAY with error → CLOSED" begin
            conn = HTTP2.HTTP2Connection()
            conn.state = HTTP2.ConnectionState.OPEN

            HTTP2.send_goaway(conn, HTTP2.ErrorCode.PROTOCOL_ERROR)

            @test conn.goaway_sent
            @test conn.state == HTTP2.ConnectionState.CLOSED
        end

        @testset "GOAWAY includes last stream ID" begin
            conn = HTTP2.HTTP2Connection()
            conn.state = HTTP2.ConnectionState.OPEN
            conn.last_client_stream_id = UInt32(7)

            goaway = HTTP2.send_goaway(conn, HTTP2.ErrorCode.NO_ERROR)
            last_stream, error_code, _ = HTTP2.parse_goaway_frame(goaway)

            @test last_stream == 7
            @test error_code == HTTP2.ErrorCode.NO_ERROR
        end

        @testset "GOAWAY with debug data" begin
            debug = Vector{UInt8}("Connection timeout")
            goaway = HTTP2.goaway_frame(0, HTTP2.ErrorCode.CANCEL, debug)
            _, _, parsed_debug = HTTP2.parse_goaway_frame(goaway)

            @test String(parsed_debug) == "Connection timeout"
        end

    end  # T039

    # =========================================================================
    # T040: Flow Control
    # =========================================================================

    @testset "T040: Flow control" begin

        @testset "Initial window size" begin
            @test HTTP2.DEFAULT_INITIAL_WINDOW_SIZE == 65535
        end

        @testset "WINDOW_UPDATE increment validation" begin
            # Valid: 1 to 2^31-1
            @test_nowarn HTTP2.window_update_frame(0, 1)
            @test_nowarn HTTP2.window_update_frame(0, 2147483647)

            # Invalid: 0
            @test_throws ArgumentError HTTP2.window_update_frame(0, 0)
        end

        @testset "WINDOW_UPDATE on connection level" begin
            frame = HTTP2.window_update_frame(0, 65535)
            @test frame.header.stream_id == 0
        end

        @testset "WINDOW_UPDATE on stream level" begin
            frame = HTTP2.window_update_frame(5, 32768)
            @test frame.header.stream_id == 5
        end

        @testset "WINDOW_UPDATE frame size" begin
            frame = HTTP2.window_update_frame(0, 65535)
            @test frame.header.length == 4
        end

    end  # T040

    # =========================================================================
    # T041: Stream Management
    # =========================================================================

    @testset "T041: Stream management" begin

        @testset "Client-initiated streams are odd" begin
            @test HTTP2.is_client_initiated(1)
            @test HTTP2.is_client_initiated(3)
            @test HTTP2.is_client_initiated(5)
            @test !HTTP2.is_client_initiated(2)
            @test !HTTP2.is_client_initiated(4)
        end

        @testset "Server-initiated streams are even" begin
            @test HTTP2.is_server_initiated(2)
            @test HTTP2.is_server_initiated(4)
            @test !HTTP2.is_server_initiated(1)
            @test !HTTP2.is_server_initiated(0)
        end

        @testset "Stream creation" begin
            conn = HTTP2.HTTP2Connection()
            conn.state = HTTP2.ConnectionState.OPEN

            stream = HTTP2.create_stream(conn, UInt32(1))
            @test stream.id == 1
            @test stream.state == HTTP2.StreamState.IDLE
        end

        @testset "Stream state transitions" begin
            stream = HTTP2.HTTP2Stream(UInt32(1))
            @test stream.state == HTTP2.StreamState.IDLE

            HTTP2.receive_headers!(stream, false)
            @test stream.state == HTTP2.StreamState.OPEN

            HTTP2.send_headers!(stream, true)
            @test stream.state == HTTP2.StreamState.HALF_CLOSED_LOCAL
        end

        @testset "RST_STREAM closes stream" begin
            stream = HTTP2.HTTP2Stream(UInt32(1))
            stream.state = HTTP2.StreamState.OPEN

            HTTP2.receive_rst_stream!(stream, UInt32(HTTP2.ErrorCode.CANCEL))
            @test HTTP2.is_closed(stream)
            @test stream.reset
        end

        @testset "Concurrent streams limit" begin
            conn = HTTP2.HTTP2Connection()
            @test conn.local_settings.max_concurrent_streams == 100
        end

    end  # T041

end  # AC6: Connection Management
