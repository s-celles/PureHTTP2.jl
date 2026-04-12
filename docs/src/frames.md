# Frames

The frames layer implements the HTTP/2 wire format per RFC 9113:
encoding and decoding the 9-byte frame header, the 10 frame types
(DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING,
GOAWAY, WINDOW_UPDATE, CONTINUATION), and a small set of
per-frame-type parser/constructor helpers. All of these are pure
`Base`-Julia operations on `Vector{UInt8}` — no C library dependency.

## Wire format constants

```@docs
HTTP2.FRAME_HEADER_SIZE
HTTP2.CONNECTION_PREFACE
HTTP2.DEFAULT_INITIAL_WINDOW_SIZE
HTTP2.DEFAULT_MAX_FRAME_SIZE
HTTP2.MIN_MAX_FRAME_SIZE
HTTP2.MAX_MAX_FRAME_SIZE
HTTP2.DEFAULT_HEADER_TABLE_SIZE
```

## Namespace submodules

RFC 9113's frame types, flags, settings parameters, and error codes
are each exposed as a submodule so callers can write
`HTTP2.FrameType.DATA`, `HTTP2.FrameFlags.END_STREAM`, etc.

```@docs
HTTP2.FrameType
HTTP2.FrameFlags
HTTP2.ErrorCode
HTTP2.SettingsParameter
```

## Frame header

```@docs
HTTP2.FrameHeader
HTTP2.encode_frame_header
HTTP2.decode_frame_header
HTTP2.has_flag
```

## Generic frame

```@docs
HTTP2.Frame
HTTP2.encode_frame
HTTP2.decode_frame
```

## Per-type constructors and parsers

These helpers build or parse specific frame types while enforcing the
type's invariants (e.g., `ping_frame` rejects non-8-byte payloads).

```@docs
HTTP2.data_frame
HTTP2.headers_frame
HTTP2.continuation_frame
HTTP2.settings_frame
HTTP2.parse_settings_frame
HTTP2.ping_frame
HTTP2.goaway_frame
HTTP2.parse_goaway_frame
HTTP2.rst_stream_frame
HTTP2.window_update_frame
HTTP2.parse_window_update_frame
```
