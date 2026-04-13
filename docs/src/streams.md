# Streams

The stream layer implements the HTTP/2 stream state machine per
RFC 9113 §5. Each [`HTTP2Stream`](@ref PureHTTP2.HTTP2Stream) owns a
state ([`StreamState`](@ref PureHTTP2.StreamState)), send and receive
flow-control windows, and buffered request/response headers and
data. The layer's functions move streams between states in
response to received or sent HEADERS, DATA, and RST_STREAM frames.

## Role signalling

The stream state machine itself is **role-neutral**: `IDLE`,
`OPEN`, `HALF_CLOSED_LOCAL`, `HALF_CLOSED_REMOTE`, and `CLOSED`
transitions work the same way from either side of the connection.
The `receive_*` and `send_*` verbs describe direction from the
caller's perspective, which reads naturally for either a server
processing a request or a client processing a response.

The HTTP and gRPC semantic accessors ([`get_method`](@ref
PureHTTP2.get_method), [`get_path`](@ref PureHTTP2.get_path),
[`get_content_type`](@ref PureHTTP2.get_content_type),
[`get_grpc_encoding`](@ref PureHTTP2.get_grpc_encoding), etc.) read
**request headers** stored on the stream — in the current
exercised code paths that means a server reading a request it
received from a client. A client assembling request headers would
set them directly on the stream and call [`send_headers!`](@ref
PureHTTP2.send_headers!). Full client-role helpers land in
**Milestone 6**.

## State enum

```@docs
PureHTTP2.StreamState
```

## Error type

```@docs
PureHTTP2.StreamError
```

## Construction

```@docs
PureHTTP2.HTTP2Stream
```

## Role predicates

```@docs
PureHTTP2.is_client_initiated
PureHTTP2.is_server_initiated
```

## Direction predicates

```@docs
PureHTTP2.can_send
PureHTTP2.can_receive
PureHTTP2.is_closed
```

## State transitions

```@docs
PureHTTP2.receive_headers!
PureHTTP2.send_headers!
PureHTTP2.receive_data!
PureHTTP2.send_data!
PureHTTP2.receive_rst_stream!
PureHTTP2.send_rst_stream!
```

## Window updates

```@docs
PureHTTP2.update_send_window!
PureHTTP2.update_recv_window!
```

## Data buffer

```@docs
PureHTTP2.get_data
PureHTTP2.peek_data
```

## HTTP semantic accessors

These helpers read well-known HTTP/2 pseudo-headers and common
headers from a stream's `request_headers` list.

```@docs
PureHTTP2.get_header
PureHTTP2.get_headers
PureHTTP2.get_method
PureHTTP2.get_path
PureHTTP2.get_authority
PureHTTP2.get_content_type
```

### gRPC convenience helpers

These are gRPC-specific shortcuts for reading headers that gRPC
adds on top of HTTP/2. They exist in PureHTTP2.jl for historical
reasons inherited from the original extraction from gRPCServer.jl
(see `upstream-bugs.md` for the layering concern). A cleaner
split would put them in a gRPC adapter rather than in PureHTTP2.jl
itself; that refactor is deferred to a future milestone.

```@docs
PureHTTP2.get_grpc_encoding
PureHTTP2.get_grpc_accept_encoding
PureHTTP2.get_grpc_timeout
PureHTTP2.get_metadata
```
