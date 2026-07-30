@testitem "Flow: window consume and release" begin
    using PureHTTP2

    window = PureHTTP2.FlowControlWindow(65535)
    @test PureHTTP2.available(window) == 65535

    # Consume some bytes
    @test PureHTTP2.consume!(window, 1000) == true
    @test PureHTTP2.available(window) == 64535

    # Release replenishes
    PureHTTP2.release!(window, 500)
    @test PureHTTP2.available(window) == 65035

    # Release the rest back to initial
    PureHTTP2.release!(window, 500)
    @test PureHTTP2.available(window) == 65535
end

@testitem "Flow: window consume with zero available" begin
    using PureHTTP2

    window = PureHTTP2.FlowControlWindow(0)
    @test PureHTTP2.available(window) == 0

    # consume! on zero-available window returns false without mutation
    @test PureHTTP2.consume!(window, 1) == false
    @test PureHTTP2.available(window) == 0

    # try_consume! returns 0 bytes consumed
    @test PureHTTP2.try_consume!(window, 10) == 0
    @test PureHTTP2.available(window) == 0

    # Consuming 0 bytes is a no-op that succeeds
    @test PureHTTP2.consume!(window, 0) == true
end

@testitem "Flow: window overflow protection" begin
    using PureHTTP2

    # release! throws ErrorException when available would exceed 2^31 − 1
    # (RFC 9113 §6.9.1 max flow-control window size).
    window = PureHTTP2.FlowControlWindow(2147483600)  # very close to max
    @test PureHTTP2.available(window) == 2147483600

    # This release would push available to 2147483700, well past the 2^31 − 1 cap
    @test_throws ErrorException PureHTTP2.release!(window, 100)

    # available stays untouched after the throw
    @test PureHTTP2.available(window) == 2147483600

    # A release that lands exactly on 2^31 − 1 is OK
    # (previous consume to free room)
    PureHTTP2.consume!(window, 47)  # down to 2147483553
    PureHTTP2.release!(window, 94)  # up to 2147483647 == 2^31 − 1 — boundary case
    @test PureHTTP2.available(window) == 2147483647
end

@testitem "Flow: window update increment" begin
    using PureHTTP2

    window = PureHTTP2.FlowControlWindow(1000)

    # Consume more than 50% (default threshold_ratio = 0.5)
    @test PureHTTP2.consume!(window, 600)
    @test PureHTTP2.should_send_update(window) == true
    @test PureHTTP2.get_update_increment(window) == 600

    # After get_update_increment the pending count resets
    @test PureHTTP2.should_send_update(window) == false
    @test PureHTTP2.get_update_increment(window) == 0

    # Custom threshold ratio
    window2 = PureHTTP2.FlowControlWindow(1000)
    PureHTTP2.consume!(window2, 100)
    @test PureHTTP2.should_send_update(window2; threshold_ratio=0.05) == true
    @test PureHTTP2.should_send_update(window2; threshold_ratio=0.5) == false
end

@testitem "Flow: initial size change" begin
    using PureHTTP2

    window = PureHTTP2.FlowControlWindow(1000)
    PureHTTP2.consume!(window, 300)
    @test PureHTTP2.available(window) == 700

    # Raising the initial size adds the delta to available
    PureHTTP2.update_initial_size!(window, 1500)
    @test window.initial_size == 1500
    @test PureHTTP2.available(window) == 1200  # 700 + 500

    # Lowering the initial size subtracts the delta
    PureHTTP2.update_initial_size!(window, 1000)
    @test PureHTTP2.available(window) == 700  # back to 700

    # Lowering so that available goes negative should throw
    window2 = PureHTTP2.FlowControlWindow(1000)
    PureHTTP2.consume!(window2, 900)  # available = 100
    @test PureHTTP2.available(window2) == 100
    @test_throws ErrorException PureHTTP2.update_initial_size!(window2, 100)
    # On throw, the window state is not guaranteed to be intact, but we assert
    # the exception fired which is the contract per src/flow_control.jl line 124.
end

@testitem "Flow: stream and connection windows interact" begin
    using PureHTTP2

    controller = PureHTTP2.FlowController()
    stream_id = UInt32(1)
    PureHTTP2.create_stream_window!(controller, stream_id)

    # Fresh controller: both windows at DEFAULT_INITIAL_WINDOW_SIZE = 65535
    @test PureHTTP2.can_send(controller, stream_id, 1000) == true
    @test PureHTTP2.max_sendable(controller, stream_id) == 65535

    # Consume from connection window directly; stream is untouched
    PureHTTP2.consume!(controller.connection_window, 60000)
    @test PureHTTP2.available(controller.connection_window) == 5535

    # can_send is false when the requested size exceeds the connection window
    # even though the stream window is still at 65535
    @test PureHTTP2.can_send(controller, stream_id, 10000) == false

    # Within the connection window's 5535 remaining bytes, we can still send
    @test PureHTTP2.can_send(controller, stream_id, 1000) == true
    @test PureHTTP2.max_sendable(controller, stream_id) == 5535

    # consume_send! from the stream-level API decrements both windows
    controller2 = PureHTTP2.FlowController()
    stream_id2 = UInt32(3)
    PureHTTP2.create_stream_window!(controller2, stream_id2)
    @test PureHTTP2.consume_send!(controller2, stream_id2, 1000) == true
    @test PureHTTP2.available(controller2.connection_window) == 64535
    stream_window = PureHTTP2.get_stream_window(controller2, stream_id2)
    @test PureHTTP2.available(stream_window) == 64535

    # Non-existent stream: can_send and consume_send! both return false
    @test PureHTTP2.can_send(controller2, UInt32(999), 100) == false
    @test PureHTTP2.consume_send!(controller2, UInt32(999), 100) == false
end

@testitem "Flow: SETTINGS initial window size change" begin
    using PureHTTP2

    controller = PureHTTP2.FlowController()
    PureHTTP2.create_stream_window!(controller, UInt32(1))
    PureHTTP2.create_stream_window!(controller, UInt32(3))
    PureHTTP2.create_stream_window!(controller, UInt32(5))

    # Consume different amounts from each stream so we can observe the delta
    PureHTTP2.consume_send!(controller, UInt32(1), 10000)   # stream 1: 55535 available
    PureHTTP2.consume_send!(controller, UInt32(3), 20000)   # stream 3: 45535 available

    w1 = PureHTTP2.get_stream_window(controller, UInt32(1))
    w3 = PureHTTP2.get_stream_window(controller, UInt32(3))
    w5 = PureHTTP2.get_stream_window(controller, UInt32(5))
    @test PureHTTP2.available(w1) == 55535
    @test PureHTTP2.available(w3) == 45535
    @test PureHTTP2.available(w5) == 65535

    # Raise initial window size by 10000 via SETTINGS
    PureHTTP2.apply_settings_initial_window_size!(controller, 75535)
    @test controller.initial_stream_window == 75535

    # Every stream window got +10000
    @test PureHTTP2.available(w1) == 65535   # 55535 + 10000
    @test PureHTTP2.available(w3) == 55535   # 45535 + 10000
    @test PureHTTP2.available(w5) == 75535   # 65535 + 10000
end

@testitem "Flow: DataSender frame splitting" begin
    using PureHTTP2

    controller = PureHTTP2.FlowController()
    stream_id = UInt32(1)
    PureHTTP2.create_stream_window!(controller, stream_id)

    # Small max_frame_size forces the data to split
    sender = PureHTTP2.DataSender(controller, 100)

    data = collect(UInt8(1):UInt8(250))  # 250 bytes
    frames = PureHTTP2.send_data_frames(sender, stream_id, data)

    # 250 bytes at 100 max/frame = 3 frames (100 + 100 + 50)
    @test length(frames) == 3
    @test frames[1].header.length == 100
    @test frames[2].header.length == 100
    @test frames[3].header.length == 50

    # First two frames must not have END_STREAM set (we didn't request it)
    @test !PureHTTP2.has_flag(frames[1].header, PureHTTP2.FrameFlags.END_STREAM)
    @test !PureHTTP2.has_flag(frames[2].header, PureHTTP2.FrameFlags.END_STREAM)
    @test !PureHTTP2.has_flag(frames[3].header, PureHTTP2.FrameFlags.END_STREAM)

    # end_stream=true attaches END_STREAM only to the last frame
    controller2 = PureHTTP2.FlowController()
    PureHTTP2.create_stream_window!(controller2, UInt32(3))
    sender2 = PureHTTP2.DataSender(controller2, 100)
    frames_es = PureHTTP2.send_data_frames(sender2, UInt32(3), data; end_stream=true)
    @test length(frames_es) == 3
    @test !PureHTTP2.has_flag(frames_es[1].header, PureHTTP2.FrameFlags.END_STREAM)
    @test !PureHTTP2.has_flag(frames_es[2].header, PureHTTP2.FrameFlags.END_STREAM)
    @test PureHTTP2.has_flag(frames_es[3].header, PureHTTP2.FrameFlags.END_STREAM)

    # The payload concatenation reproduces the original data
    reconstructed = vcat(frames[1].payload, frames[2].payload, frames[3].payload)
    @test reconstructed == data
end

@testitem "Flow: send and receive windows are independent" begin
    using PureHTTP2

    # RFC 7540 §6.9.2: SETTINGS_INITIAL_WINDOW_SIZE governs the *send* direction —
    # how much the sender may put on a stream. The receiver's own window is
    # governed by the value it advertises itself. Conflating the two made every
    # receive window adopt the peer's advertised size, so the refresh threshold
    # was never reached and stream-level WINDOW_UPDATEs were never emitted.
    #
    # §6.9.2 also states the connection window is not affected by
    # SETTINGS_INITIAL_WINDOW_SIZE: it starts at 65535 in both directions.

    @testset "connection windows always start at 65535" begin
        controller = PureHTTP2.FlowController(1_000_000;
                                              recv_initial_window_size = 2_000_000)
        @test PureHTTP2.available(controller.connection_window) ==
              PureHTTP2.DEFAULT_INITIAL_WINDOW_SIZE
        @test PureHTTP2.available(controller.recv_connection_window) ==
              PureHTTP2.DEFAULT_INITIAL_WINDOW_SIZE
    end

    @testset "stream windows take their own side's initial size" begin
        controller = PureHTTP2.FlowController(1_000_000;
                                              recv_initial_window_size = 65_535)
        PureHTTP2.create_stream_window!(controller, UInt32(1))
        @test PureHTTP2.available(
            PureHTTP2.get_stream_window(controller, UInt32(1))) == 1_000_000
        @test PureHTTP2.available(
            PureHTTP2.get_recv_stream_window(controller, UInt32(1))) == 65_535
    end

    @testset "the peer's SETTINGS resizes send windows only" begin
        controller = PureHTTP2.FlowController(65_535; recv_initial_window_size = 65_535)
        PureHTTP2.create_stream_window!(controller, UInt32(1))
        PureHTTP2.apply_settings_initial_window_size!(controller, 1_000_000)
        @test PureHTTP2.available(
            PureHTTP2.get_stream_window(controller, UInt32(1))) == 1_000_000
        @test PureHTTP2.available(
            PureHTTP2.get_recv_stream_window(controller, UInt32(1))) == 65_535
    end

    @testset "updates are generated from the receive side" begin
        # A peer advertising a large window must not delay our own updates.
        controller = PureHTTP2.FlowController(10_485_760;
                                              recv_initial_window_size = 65_535)
        PureHTTP2.create_stream_window!(controller, UInt32(1))
        PureHTTP2.consume_recv!(controller, UInt32(1), 40_000)
        updates = PureHTTP2.generate_window_updates(controller)
        @test sort([Int(f.header.stream_id) for f in updates]) == [0, 1]
    end

    @testset "emitting an update replenishes our own receive window" begin
        # get_update_increment only clears pending_updates; the granted bytes must
        # be added back to `available` or the window drains to zero and legitimate
        # DATA is rejected as a flow-control violation after the first 65535 bytes.
        controller = PureHTTP2.FlowController(; recv_initial_window_size = 65_535)
        PureHTTP2.create_stream_window!(controller, UInt32(1))
        PureHTTP2.consume_recv!(controller, UInt32(1), 40_000)
        @test PureHTTP2.available(controller.recv_connection_window) == 25_535
        PureHTTP2.generate_window_updates(controller)
        @test PureHTTP2.available(controller.recv_connection_window) == 65_535
        @test PureHTTP2.available(
            PureHTTP2.get_recv_stream_window(controller, UInt32(1))) == 65_535
    end

    @testset "consume_recv! reports which window a peer overran" begin
        controller = PureHTTP2.FlowController(; recv_initial_window_size = 65_535)
        PureHTTP2.create_stream_window!(controller, UInt32(1))
        @test PureHTTP2.consume_recv!(controller, UInt32(1), 1000) === :ok
        @test PureHTTP2.consume_recv!(controller, UInt32(1), 65_535) === :connection_exceeded
    end

    @testset "removing a stream drops both of its windows" begin
        controller = PureHTTP2.FlowController()
        PureHTTP2.create_stream_window!(controller, UInt32(1))
        PureHTTP2.remove_stream_window!(controller, UInt32(1))
        @test PureHTTP2.get_stream_window(controller, UInt32(1)) === nothing
        @test PureHTTP2.get_recv_stream_window(controller, UInt32(1)) === nothing
    end
end

@testitem "Flow: receive accounting tracks the peer's real allowance" begin
    using PureHTTP2

    # The receive window must equal (total granted) - (total received) at all
    # times. A peer that respects the allowance we advertised must never be
    # reported as violating it.
    #
    # Regression guard: a wire capture showed the server emitting
    # RST_STREAM(FLOW_CONTROL_ERROR) against perfectly legal traffic, which
    # aborted every request larger than one window. The rejection came from
    # consume_recv! deciding the peer had overrun a window that our own
    # bookkeeping had drifted away from.

    @testset "a well-behaved peer is never reported as violating" begin
        controller = PureHTTP2.FlowController(; recv_initial_window_size = 65_535)
        PureHTTP2.create_stream_window!(controller, UInt32(1))

        granted = PureHTTP2.DEFAULT_INITIAL_WINDOW_SIZE   # what the peer may send now
        received = 0
        chunk = 16_384

        # Drive far past a single window, the way a 200KB request does.
        for _ in 1:60
            n = min(chunk, granted - received)
            n <= 0 && break
            status = PureHTTP2.consume_recv!(controller, UInt32(1), n)
            @test status === :ok           # legal traffic, never a violation
            received += n

            for f in PureHTTP2.generate_window_updates(controller)
                if f.header.stream_id == 0
                    granted += (UInt32(f.payload[1]) << 24) | (UInt32(f.payload[2]) << 16) |
                               (UInt32(f.payload[3]) << 8) | UInt32(f.payload[4])
                end
            end
        end

        # The peer got room to send well beyond the first window.
        @test received > 2 * PureHTTP2.DEFAULT_INITIAL_WINDOW_SIZE

        # And our own view matches the ledger exactly.
        @test PureHTTP2.available(controller.recv_connection_window) == granted - received
    end

    @testset "the window never drifts below the ledger across streams" begin
        # Streams come and go; bytes consumed on a closed stream must not
        # permanently erode the shared connection window.
        controller = PureHTTP2.FlowController(; recv_initial_window_size = 65_535)
        granted = PureHTTP2.DEFAULT_INITIAL_WINDOW_SIZE
        received = 0

        for id in UInt32.(1:2:11)
            PureHTTP2.create_stream_window!(controller, id)
            for _ in 1:3
                n = min(16_384, granted - received)
                n <= 0 && break
                @test PureHTTP2.consume_recv!(controller, id, n) === :ok
                received += n
                for f in PureHTTP2.generate_window_updates(controller)
                    if f.header.stream_id == 0
                        granted += (UInt32(f.payload[1]) << 24) | (UInt32(f.payload[2]) << 16) |
                                   (UInt32(f.payload[3]) << 8) | UInt32(f.payload[4])
                    end
                end
            end
            PureHTTP2.remove_stream_window!(controller, id)
        end

        @test PureHTTP2.available(controller.recv_connection_window) == granted - received
    end
end
