# HTTP/2 Protocol Conformance Tests — reduced at M2.
# Frame-related testsets have been migrated to test/testitems_frames.jl.
# The Stream state machine and Connection preface processing testsets
# below remain here until Milestone 3 migrates them to native @testitem
# form.
# Reference: RFC 7540 - Hypertext Transfer Protocol Version 2 (HTTP/2)

using Test
using HTTP2

@testset "HTTP/2 Protocol Conformance (stream/preface, pending M3)" begin

    # =========================================================================
    # Stream State Machine Tests
    # =========================================================================

    @testset "Stream state machine" begin

        @testset "Stream states per RFC 7540 Section 5.1" begin
            @test HTTP2.StreamState.IDLE isa HTTP2.StreamState.T
            @test HTTP2.StreamState.OPEN isa HTTP2.StreamState.T
            @test HTTP2.StreamState.HALF_CLOSED_LOCAL isa HTTP2.StreamState.T
            @test HTTP2.StreamState.HALF_CLOSED_REMOTE isa HTTP2.StreamState.T
            @test HTTP2.StreamState.CLOSED isa HTTP2.StreamState.T
        end

        @testset "Stream transitions: IDLE -> OPEN on HEADERS" begin
            stream = HTTP2.HTTP2Stream(UInt32(1))
            @test stream.state == HTTP2.StreamState.IDLE

            HTTP2.receive_headers!(stream, false)  # Not END_STREAM
            @test stream.state == HTTP2.StreamState.OPEN
        end

        @testset "Stream transitions: IDLE -> HALF_CLOSED_REMOTE on HEADERS with END_STREAM" begin
            stream = HTTP2.HTTP2Stream(UInt32(1))
            @test stream.state == HTTP2.StreamState.IDLE

            HTTP2.receive_headers!(stream, true)  # END_STREAM
            @test stream.state == HTTP2.StreamState.HALF_CLOSED_REMOTE
            @test stream.end_stream_received
        end

        @testset "Stream transitions: OPEN -> HALF_CLOSED_LOCAL on send END_STREAM" begin
            stream = HTTP2.HTTP2Stream(UInt32(1))
            stream.state = HTTP2.StreamState.OPEN

            HTTP2.send_headers!(stream, true)  # END_STREAM
            @test stream.state == HTTP2.StreamState.HALF_CLOSED_LOCAL
            @test stream.end_stream_sent
        end

        @testset "Client vs server initiated streams" begin
            @test HTTP2.is_client_initiated(1)
            @test HTTP2.is_client_initiated(3)
            @test HTTP2.is_client_initiated(5)
            @test !HTTP2.is_client_initiated(2)
            @test !HTTP2.is_client_initiated(4)

            @test HTTP2.is_server_initiated(2)
            @test HTTP2.is_server_initiated(4)
            @test !HTTP2.is_server_initiated(1)
            @test !HTTP2.is_server_initiated(0)  # Stream 0 is connection-level
        end

    end

    # =========================================================================
    # Connection Preface Processing
    # =========================================================================

    @testset "Connection preface processing" begin

        @testset "Valid connection preface" begin
            conn = HTTP2.HTTP2Connection()
            @test conn.state == HTTP2.ConnectionState.PREFACE

            preface = Vector{UInt8}(HTTP2.CONNECTION_PREFACE)
            success, response_frames = HTTP2.process_preface(conn, preface)

            @test success
            @test conn.state == HTTP2.ConnectionState.OPEN
            @test length(response_frames) >= 1
            # First response frame should be SETTINGS
            @test response_frames[1].header.frame_type == HTTP2.FrameType.SETTINGS
        end

        @testset "Invalid connection preface" begin
            conn = HTTP2.HTTP2Connection()

            # Preface that matches in length but has wrong content throws error
            invalid_preface = Vector{UInt8}("PRI * HTTP/1.1\r\n\r\nSM\r\n\r\n")
            @test_throws HTTP2.ConnectionError HTTP2.process_preface(conn, invalid_preface)

            # Too short preface returns false (not enough data yet)
            conn2 = HTTP2.HTTP2Connection()
            short_preface = Vector{UInt8}("PRI")
            success, _ = HTTP2.process_preface(conn2, short_preface)
            @test !success
        end

    end

end  # HTTP/2 Protocol Conformance (stream/preface, pending M3)
