# Connection

The connection layer owns an HTTP/2 connection's lifecycle: the
preface handshake, SETTINGS exchange, GOAWAY, and dispatch of
incoming frames to the appropriate state-machine handlers. An
[`HTTP2Connection`](@ref PureHTTP2.HTTP2Connection) holds the local
and remote [`ConnectionSettings`](@ref PureHTTP2.ConnectionSettings),
the set of active streams, the HPACK encoder/decoder pair, the
[`FlowController`](@ref PureHTTP2.FlowController), and the current
[`ConnectionState`](@ref PureHTTP2.ConnectionState).

## Role signalling

The connection layer is **currently server-role only**. Specifically:

- [`process_preface`](@ref PureHTTP2.process_preface) processes the
  **client** connection preface received over the wire from a
  client — i.e., the server side of the handshake.
- The `process_*_frame!` family is exercised exclusively by
  server-side code paths in the current test suite.
- The outbound `send_*` APIs ([`send_headers`](@ref
  PureHTTP2.send_headers), [`send_data`](@ref PureHTTP2.send_data),
  [`send_goaway`](@ref PureHTTP2.send_goaway), etc.) are role-neutral
  in their signatures, but the documented exercised paths build
  them in server-role contexts.

**Milestone 6** adds client-role connection setup — sending the
preface, processing the server's SETTINGS, and verifying the
outbound `send_*` APIs work from a client context.

## State enum

```@docs
PureHTTP2.ConnectionState
```

## Error type

```@docs
PureHTTP2.ConnectionError
```

## Connection and settings

```@docs
PureHTTP2.HTTP2Connection
PureHTTP2.ConnectionSettings
PureHTTP2.apply_settings!
PureHTTP2.to_frame
```

## Stream lifecycle

```@docs
PureHTTP2.get_stream
PureHTTP2.can_send_on_stream
PureHTTP2.create_stream
PureHTTP2.remove_stream
PureHTTP2.active_stream_count
```

## Preface (server role)

```@docs
PureHTTP2.process_preface
```

## Frame processing (server role)

```@docs
PureHTTP2.process_frame
PureHTTP2.process_settings_frame!
PureHTTP2.process_ping_frame!
PureHTTP2.process_goaway_frame!
PureHTTP2.process_window_update_frame!
PureHTTP2.process_headers_frame!
PureHTTP2.process_continuation_frame!
PureHTTP2.process_data_frame!
PureHTTP2.process_rst_stream_frame!
```

## Outbound APIs

```@docs
PureHTTP2.send_headers
PureHTTP2.send_data
PureHTTP2.send_trailers
PureHTTP2.send_rst_stream
PureHTTP2.send_goaway
```

## State predicates

```@docs
PureHTTP2.is_open
```

`is_closed` is also defined for `HTTP2Connection` and shares its
name with the stream-layer method — see [Streams](@ref) for the
shared export.
