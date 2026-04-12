# API Reference

The HPACK and frame public API — which is also the full list of
symbols exported from `HTTP2` — is documented on dedicated pages:

- **[Frames](@ref)** — wire format, frame header, per-type
  constructors and parsers, namespace submodules for frame types,
  flags, settings parameters, and error codes.
- **[HPACK](@ref)** — encoder/decoder, dynamic table, low-level
  primitives.

This page exists to hold doc references for the stream, connection,
and flow-control layers that are documented in the tree but not yet
exported. They become fully public in Milestone 3.

## Flow control (not yet exported — M3)

```@docs
HTTP2.FlowControlWindow
HTTP2.FlowController
```

## Stream (not yet exported — M3)

```@docs
HTTP2.HTTP2Stream
HTTP2.StreamState
HTTP2.StreamError
```

## Connection (not yet exported — M3)

```@docs
HTTP2.HTTP2Connection
HTTP2.ConnectionState
HTTP2.ConnectionError
```
