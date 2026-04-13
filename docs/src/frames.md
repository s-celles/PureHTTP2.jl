# Frames

The frames layer implements the HTTP/2 wire format per RFC 9113:
encoding and decoding the 9-byte frame header, the 10 frame types
(DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING,
GOAWAY, WINDOW_UPDATE, CONTINUATION), and a small set of
per-frame-type parser/constructor helpers. All of these are pure
`Base`-Julia operations on `Vector{UInt8}` — no C library dependency.

## Wire format constants

```@docs
PureHTTP2.FRAME_HEADER_SIZE
PureHTTP2.CONNECTION_PREFACE
PureHTTP2.DEFAULT_INITIAL_WINDOW_SIZE
PureHTTP2.DEFAULT_MAX_FRAME_SIZE
PureHTTP2.MIN_MAX_FRAME_SIZE
PureHTTP2.MAX_MAX_FRAME_SIZE
PureHTTP2.DEFAULT_HEADER_TABLE_SIZE
```

## Namespace submodules

RFC 9113's frame types, flags, settings parameters, and error codes
are each exposed as a submodule so callers can write
`PureHTTP2.FrameType.DATA`, `PureHTTP2.FrameFlags.END_STREAM`, etc.

```@docs
PureHTTP2.FrameType
PureHTTP2.FrameFlags
PureHTTP2.ErrorCode
PureHTTP2.SettingsParameter
```

## Frame header

```@docs
PureHTTP2.FrameHeader
PureHTTP2.encode_frame_header
PureHTTP2.decode_frame_header
PureHTTP2.has_flag
```

## Generic frame

```@docs
PureHTTP2.Frame
PureHTTP2.encode_frame
PureHTTP2.decode_frame
```

## Per-type constructors and parsers

These helpers build or parse specific frame types while enforcing the
type's invariants (e.g., `ping_frame` rejects non-8-byte payloads).

```@docs
PureHTTP2.data_frame
PureHTTP2.headers_frame
PureHTTP2.continuation_frame
PureHTTP2.settings_frame
PureHTTP2.parse_settings_frame
PureHTTP2.ping_frame
PureHTTP2.goaway_frame
PureHTTP2.parse_goaway_frame
PureHTTP2.rst_stream_frame
PureHTTP2.window_update_frame
PureHTTP2.parse_window_update_frame
```
