# API Reference

This page lists the types and functions HTTP2.jl documents at Milestone 1.
The surface is intentionally narrow — public-API curation is the
responsibility of Milestones 2 and 3 (Frames/HPACK, Stream/Connection).
Undocumented internals are not broken; they are simply not yet part of
the committed interface.

## HPACK

```@docs
HTTP2.DynamicTable
HTTP2.HPACKEncoder
HTTP2.HPACKDecoder
```

## Flow control

```@docs
HTTP2.FlowControlWindow
HTTP2.FlowController
```

## Frames

```@docs
HTTP2.FrameHeader
HTTP2.Frame
HTTP2.FrameType
HTTP2.FrameFlags
HTTP2.ErrorCode
HTTP2.SettingsParameter
```

## Stream

```@docs
HTTP2.HTTP2Stream
HTTP2.StreamState
HTTP2.StreamError
```

## Connection

```@docs
HTTP2.HTTP2Connection
HTTP2.ConnectionState
HTTP2.ConnectionError
```
