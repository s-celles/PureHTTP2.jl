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
