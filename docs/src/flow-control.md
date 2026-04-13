# Flow control

HTTP/2 defines two levels of flow control (RFC 9113 §5.2): the
connection-level window and a per-stream window. PureHTTP2.jl models
both as [`FlowControlWindow`](@ref PureHTTP2.FlowControlWindow)
instances. The [`FlowController`](@ref PureHTTP2.FlowController) ties
them together — it owns one connection window and a dictionary of
stream windows keyed by stream ID, and its operations correctly
decrement **both** windows when a stream sends or receives DATA.

Above that, [`DataSender`](@ref PureHTTP2.DataSender) and
[`DataReceiver`](@ref PureHTTP2.DataReceiver) layer frame-size limits
on top of the flow controller, splitting outgoing DATA into frames
no larger than the peer's `MAX_FRAME_SIZE`.

## Role signalling

Flow control is **role-neutral**. A `FlowControlWindow` is a
sliding window regardless of who created it, and the
`FlowController` distinguishes only connection-level from
stream-level — never server from client. The
[`apply_settings_initial_window_size!`](@ref
PureHTTP2.apply_settings_initial_window_size!) function responds to a
peer's SETTINGS frame the same way whether that frame came from a
server or a client.

Client-role code that sends DATA constructs the same `DataSender`
shape as server-role code; the roles diverge only in which side
originally advertises the initial window.

## Window

```@docs
PureHTTP2.FlowControlWindow
```

## Window operations

```@docs
PureHTTP2.consume!
PureHTTP2.try_consume!
PureHTTP2.release!
PureHTTP2.available
PureHTTP2.should_send_update
PureHTTP2.get_update_increment
PureHTTP2.update_initial_size!
```

## Multi-stream controller

```@docs
PureHTTP2.FlowController
```

## Controller operations

```@docs
PureHTTP2.create_stream_window!
PureHTTP2.get_stream_window
PureHTTP2.remove_stream_window!
PureHTTP2.consume_send!
PureHTTP2.max_sendable
PureHTTP2.apply_window_update!
PureHTTP2.apply_settings_initial_window_size!
PureHTTP2.generate_window_updates
```

## High-level senders and receivers

```@docs
PureHTTP2.DataSender
PureHTTP2.send_data_frames
PureHTTP2.DataReceiver
```
