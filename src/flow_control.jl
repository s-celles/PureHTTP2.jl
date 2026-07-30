# HTTP/2 flow control for PureHTTP2.jl
# Per RFC 7540 Section 5.2: Flow Control

# Note: frames.jl must be included before this file

"""
    FlowControlWindow(initial_size::Int = DEFAULT_INITIAL_WINDOW_SIZE)

A single HTTP/2 flow-control window (RFC 9113 §5.2). Can represent
either a connection-level window or a stream-level window. Thread-
safe via an internal `ReentrantLock`.

# Fields
- `available::Int`: Available window size
- `initial_size::Int`: Initial window size
- `pending_updates::Int`: Pending WINDOW_UPDATE bytes to send
- `lock::ReentrantLock`: Thread-safe access

# Example

```jldoctest
julia> using PureHTTP2

julia> window = FlowControlWindow(65535);

julia> consume!(window, 1000)
true

julia> available(window)
64535

julia> release!(window, 1000);

julia> available(window)
65535
```
"""
mutable struct FlowControlWindow
    available::Int
    initial_size::Int
    pending_updates::Int
    lock::ReentrantLock

    function FlowControlWindow(initial_size::Int=DEFAULT_INITIAL_WINDOW_SIZE)
        new(initial_size, initial_size, 0, ReentrantLock())
    end
end

"""
    consume!(window::FlowControlWindow, size::Int) -> Bool

Consume bytes from the flow control window.
Returns true if consumption was successful, false if insufficient window.
"""
function consume!(window::FlowControlWindow, size::Int)::Bool
    lock(window.lock) do
        if size > window.available
            return false
        end
        window.available -= size
        window.pending_updates += size
        return true
    end
end

"""
    try_consume!(window::FlowControlWindow, size::Int) -> Int

Try to consume up to `size` bytes from the window.
Returns the actual number of bytes consumed.
"""
function try_consume!(window::FlowControlWindow, size::Int)::Int
    lock(window.lock) do
        consumed = min(size, window.available)
        window.available -= consumed
        window.pending_updates += consumed
        return consumed
    end
end

"""
    release!(window::FlowControlWindow, size::Int)

Release bytes back to the flow control window (for WINDOW_UPDATE).
"""
function release!(window::FlowControlWindow, size::Int)
    lock(window.lock) do
        new_available = window.available + size
        if new_available > 2147483647  # 2^31 - 1
            throw(ErrorException("Flow control window overflow"))
        end
        window.available = new_available
        window.pending_updates = max(0, window.pending_updates - size)
    end
end

"""
    available(window::FlowControlWindow) -> Int

Get the current available window size.
"""
function available(window::FlowControlWindow)::Int
    lock(window.lock) do
        return window.available
    end
end

"""
    should_send_update(window::FlowControlWindow; threshold_ratio::Float64=0.5) -> Bool

Check if a WINDOW_UPDATE should be sent based on pending updates.
"""
function should_send_update(window::FlowControlWindow; threshold_ratio::Float64=0.5)::Bool
    lock(window.lock) do
        threshold = floor(Int, window.initial_size * threshold_ratio)
        return window.pending_updates >= threshold
    end
end

"""
    get_update_increment(window::FlowControlWindow) -> Int

Get the increment for WINDOW_UPDATE and reset pending updates.
"""
function get_update_increment(window::FlowControlWindow)::Int
    lock(window.lock) do
        increment = window.pending_updates
        window.pending_updates = 0
        return increment
    end
end

"""
    update_initial_size!(window::FlowControlWindow, new_initial_size::Int)

Update the initial window size (from SETTINGS frame).
Adjusts the current available window proportionally.
"""
function update_initial_size!(window::FlowControlWindow, new_initial_size::Int)
    lock(window.lock) do
        delta = new_initial_size - window.initial_size
        new_available = window.available + delta

        if new_available < 0 || new_available > 2147483647
            throw(ErrorException("Flow control window overflow after SETTINGS"))
        end

        window.available = new_available
        window.initial_size = new_initial_size
    end
end

"""
    FlowController

Manages flow control for an HTTP/2 connection, in both directions.

The two directions are governed by different values and must not share windows
(RFC 7540 §6.9.2):

- **Send** — how much we may transmit. Stream windows are sized by the *peer's*
  advertised `SETTINGS_INITIAL_WINDOW_SIZE` and credited by the WINDOW_UPDATE
  frames it sends us.
- **Receive** — how much we let the peer transmit. Stream windows are sized by
  the value *we* advertise, and we replenish them by emitting WINDOW_UPDATE as we
  consume received DATA.

Conflating them means a peer advertising a large window (gRPCClient.jl advertises
10 MB) also enlarges our receive windows, so the refresh threshold is never
reached, no stream-level WINDOW_UPDATE is ever emitted, and the peer stalls once
it has sent the initial window.

Connection-level windows always start at `DEFAULT_INITIAL_WINDOW_SIZE` in both
directions: §6.9.2 states that `SETTINGS_INITIAL_WINDOW_SIZE` applies to stream
windows only and never to the connection window.

# Fields
- `connection_window::FlowControlWindow`: Connection-level send window
- `stream_windows::Dict{UInt32, FlowControlWindow}`: Per-stream send windows
- `initial_stream_window::Int`: Initial size for new stream *send* windows
- `recv_connection_window::FlowControlWindow`: Connection-level receive window
- `recv_stream_windows::Dict{UInt32, FlowControlWindow}`: Per-stream receive windows
- `initial_recv_stream_window::Int`: Initial size for new stream *receive* windows
- `lock::ReentrantLock`: Thread-safe access to both stream window dicts
"""
mutable struct FlowController
    connection_window::FlowControlWindow
    stream_windows::Dict{UInt32, FlowControlWindow}
    initial_stream_window::Int
    recv_connection_window::FlowControlWindow
    recv_stream_windows::Dict{UInt32, FlowControlWindow}
    initial_recv_stream_window::Int
    lock::ReentrantLock

    function FlowController(initial_window_size::Int=DEFAULT_INITIAL_WINDOW_SIZE;
                            recv_initial_window_size::Int=DEFAULT_INITIAL_WINDOW_SIZE)
        new(
            FlowControlWindow(DEFAULT_INITIAL_WINDOW_SIZE),
            Dict{UInt32, FlowControlWindow}(),
            initial_window_size,
            FlowControlWindow(DEFAULT_INITIAL_WINDOW_SIZE),
            Dict{UInt32, FlowControlWindow}(),
            recv_initial_window_size,
            ReentrantLock()
        )
    end
end

"""
    create_stream_window!(controller::FlowController, stream_id::UInt32) -> FlowControlWindow

Create a flow control window for a new stream.
"""
function create_stream_window!(controller::FlowController, stream_id::UInt32)::FlowControlWindow
    lock(controller.lock) do
        if !haskey(controller.recv_stream_windows, stream_id)
            controller.recv_stream_windows[stream_id] =
                FlowControlWindow(controller.initial_recv_stream_window)
        end
        if haskey(controller.stream_windows, stream_id)
            return controller.stream_windows[stream_id]
        end
        window = FlowControlWindow(controller.initial_stream_window)
        controller.stream_windows[stream_id] = window
        return window
    end
end

"""
    get_recv_stream_window(controller::FlowController, stream_id::UInt32) -> Union{FlowControlWindow, Nothing}

Get the *receive* window for a stream — how much more the peer may send on it.
See [`get_stream_window`](@ref) for the send-side counterpart.
"""
function get_recv_stream_window(controller::FlowController, stream_id::UInt32)::Union{FlowControlWindow, Nothing}
    lock(controller.lock) do
        return get(controller.recv_stream_windows, stream_id, nothing)
    end
end

"""
    consume_recv!(controller::FlowController, stream_id::UInt32, size::Int) -> Symbol

Account `size` bytes of received DATA against the connection and stream receive
windows.

Returns `:ok`, or `:connection_exceeded` / `:stream_exceeded` when the peer sent
more than the corresponding window allowed — a flow-control violation the caller
should surface as `FLOW_CONTROL_ERROR` (RFC 7540 §6.9).

The consumed bytes become `pending_updates`, which is what
[`generate_window_updates`](@ref) turns into WINDOW_UPDATE frames.
"""
function consume_recv!(controller::FlowController, stream_id::UInt32, size::Int)::Symbol
    if !consume!(controller.recv_connection_window, size)
        return :connection_exceeded
    end
    window = get_recv_stream_window(controller, stream_id)
    if window !== nothing && !consume!(window, size)
        return :stream_exceeded
    end
    return :ok
end

"""
    get_stream_window(controller::FlowController, stream_id::UInt32) -> Union{FlowControlWindow, Nothing}

Get the flow control window for a stream.
"""
function get_stream_window(controller::FlowController, stream_id::UInt32)::Union{FlowControlWindow, Nothing}
    lock(controller.lock) do
        return get(controller.stream_windows, stream_id, nothing)
    end
end

"""
    remove_stream_window!(controller::FlowController, stream_id::UInt32)

Remove the flow control window for a closed stream.
"""
function remove_stream_window!(controller::FlowController, stream_id::UInt32)
    lock(controller.lock) do
        delete!(controller.stream_windows, stream_id)
        delete!(controller.recv_stream_windows, stream_id)
    end
end

"""
    can_send(controller::FlowController, stream_id::UInt32, size::Int) -> Bool

Check if data of the given size can be sent on the stream.
"""
function can_send(controller::FlowController, stream_id::UInt32, size::Int)::Bool
    # Check connection window
    if available(controller.connection_window) < size
        return false
    end

    # Check stream window
    stream_window = get_stream_window(controller, stream_id)
    if stream_window === nothing
        return false
    end

    return available(stream_window) >= size
end

"""
    consume_send!(controller::FlowController, stream_id::UInt32, size::Int) -> Bool

Consume bytes from both connection and stream windows for sending.
"""
function consume_send!(controller::FlowController, stream_id::UInt32, size::Int)::Bool
    stream_window = get_stream_window(controller, stream_id)
    if stream_window === nothing
        return false
    end

    # Check both windows first
    if available(controller.connection_window) < size || available(stream_window) < size
        return false
    end

    # Consume from both
    if !consume!(controller.connection_window, size)
        return false
    end

    if !consume!(stream_window, size)
        # Rollback connection window
        release!(controller.connection_window, size)
        return false
    end

    return true
end

"""
    max_sendable(controller::FlowController, stream_id::UInt32) -> Int

Get the maximum sendable bytes considering both connection and stream windows.
"""
function max_sendable(controller::FlowController, stream_id::UInt32)::Int
    stream_window = get_stream_window(controller, stream_id)
    if stream_window === nothing
        return 0
    end

    conn_available = available(controller.connection_window)
    stream_available = available(stream_window)

    return min(conn_available, stream_available)
end

"""
    apply_window_update!(controller::FlowController, stream_id::UInt32, increment::Int)

Apply a received WINDOW_UPDATE to the appropriate window.
Stream ID 0 updates the connection window.
"""
function apply_window_update!(controller::FlowController, stream_id::UInt32, increment::Int)
    if stream_id == 0
        release!(controller.connection_window, increment)
    else
        stream_window = get_stream_window(controller, stream_id)
        if stream_window !== nothing
            release!(stream_window, increment)
        end
    end
end

"""
    apply_settings_initial_window_size!(controller::FlowController, new_size::Int)

Apply a new initial window size from SETTINGS to all existing streams.
"""
function apply_settings_initial_window_size!(controller::FlowController, new_size::Int)
    old_size = controller.initial_stream_window
    controller.initial_stream_window = new_size
    delta = new_size - old_size

    lock(controller.lock) do
        for (_, window) in controller.stream_windows
            update_initial_size!(window, new_size)
        end
    end
end

"""
    generate_window_updates(controller::FlowController;
                            threshold_ratio::Float64=0.5) -> Vector{Frame}

Generate WINDOW_UPDATE frames for windows that need updating.
"""
function generate_window_updates(controller::FlowController;
                                  threshold_ratio::Float64=0.5)::Vector{Frame}
    frames = Frame[]

    # Receive side only: a WINDOW_UPDATE tells the *peer* it may send more, so it
    # is generated from what we have consumed of our own receive windows. Reading
    # the send windows here would report our own remaining allowance instead.
    if should_send_update(controller.recv_connection_window; threshold_ratio=threshold_ratio)
        increment = get_update_increment(controller.recv_connection_window)
        if increment > 0
            # Emitting the frame grants the peer that many bytes again, so our own
            # accounting of what it may still send has to grow by the same amount.
            # `get_update_increment` only clears `pending_updates`; without this the
            # receive window drains to zero and legitimate DATA is rejected as a
            # flow-control violation.
            release!(controller.recv_connection_window, increment)
            push!(frames, window_update_frame(0, increment))
        end
    end

    # Stream-level updates
    lock(controller.lock) do
        for (stream_id, window) in controller.recv_stream_windows
            if should_send_update(window; threshold_ratio=threshold_ratio)
                increment = get_update_increment(window)
                if increment > 0
                    release!(window, increment)   # see the connection-level note above
                    push!(frames, window_update_frame(stream_id, increment))
                end
            end
        end
    end

    return frames
end

"""
    DataSender

Manages sending data with flow control and frame size limits.

# Fields
- `controller::FlowController`: Flow controller
- `max_frame_size::Int`: Maximum frame payload size
"""
struct DataSender
    controller::FlowController
    max_frame_size::Int

    DataSender(controller::FlowController, max_frame_size::Int=DEFAULT_MAX_FRAME_SIZE) =
        new(controller, max_frame_size)
end

"""
    send_data_frames(sender::DataSender, stream_id::UInt32, data::Vector{UInt8};
                     end_stream::Bool=false) -> Vector{Frame}

Split data into frames respecting flow control and frame size limits.
Returns empty vector if no data can be sent due to flow control.
"""
function send_data_frames(sender::DataSender, stream_id::UInt32, data::Vector{UInt8};
                          end_stream::Bool=false)::Vector{Frame}
    frames = Frame[]
    offset = 1
    remaining = length(data)

    while remaining > 0
        # Calculate how much we can send
        max_size = min(remaining, sender.max_frame_size)
        sendable = max_sendable(sender.controller, stream_id)

        if sendable == 0
            break  # Flow control blocked
        end

        chunk_size = min(max_size, sendable)
        is_last = (offset + chunk_size - 1 >= length(data))
        end_flag = end_stream && is_last

        # Consume from flow control
        if !consume_send!(sender.controller, stream_id, chunk_size)
            break  # Shouldn't happen but be safe
        end

        # Create frame
        chunk = data[offset:(offset + chunk_size - 1)]
        frame = data_frame(stream_id, chunk; end_stream=end_flag)
        push!(frames, frame)

        offset += chunk_size
        remaining -= chunk_size
    end

    return frames
end

"""
    DataReceiver

Manages receiving data with flow control.

# Fields
- `controller::FlowController`: Flow controller
- `max_frame_size::Int`: Maximum allowed frame payload size
"""
struct DataReceiver
    controller::FlowController
    max_frame_size::Int

    DataReceiver(controller::FlowController, max_frame_size::Int=DEFAULT_MAX_FRAME_SIZE) =
        new(controller, max_frame_size)
end

"""
    receive_data!(receiver::DataReceiver, stream_id::UInt32, frame::Frame) -> Vector{UInt8}

Process a received DATA frame and return the payload.
Generates WINDOW_UPDATE frames if needed (call generate_window_updates after).
"""
function receive_data!(receiver::DataReceiver, stream_id::UInt32, frame::Frame)::Vector{UInt8}
    if frame.header.frame_type != FrameType.DATA
        throw(ArgumentError("Expected DATA frame"))
    end

    if frame.header.length > receiver.max_frame_size
        throw(ErrorException("Frame size exceeds maximum: $(frame.header.length) > $(receiver.max_frame_size)"))
    end

    # Consume from stream window (receiver perspective - we're receiving, not sending)
    # The receiver tracks what it has received and will send WINDOW_UPDATE
    stream_window = get_stream_window(receiver.controller, stream_id)
    if stream_window !== nothing
        consume!(stream_window, Int(frame.header.length))
    end
    consume!(receiver.controller.connection_window, Int(frame.header.length))

    return frame.payload
end

function Base.show(io::IO, window::FlowControlWindow)
    print(io, "FlowControlWindow(available=$(window.available), initial=$(window.initial_size), pending=$(window.pending_updates))")
end

function Base.show(io::IO, controller::FlowController)
    print(io, "FlowController(connection=$(available(controller.connection_window)), streams=$(length(controller.stream_windows)))")
end
