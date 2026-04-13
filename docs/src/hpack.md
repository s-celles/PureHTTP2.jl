# HPACK

The HPACK layer implements header compression per RFC 7541. An
[`HPACKEncoder`](@ref PureHTTP2.HPACKEncoder) and
[`HPACKDecoder`](@ref PureHTTP2.HPACKDecoder) each maintain a dynamic
table of up to `max_table_size` bytes, sharing a statically-defined
table of 61 common headers. PureHTTP2.jl's HPACK implementation is
cross-validated in CI against the industry
[`http2jp/hpack-test-case`](https://github.com/http2jp/hpack-test-case)
vector set (four independent producers — `nghttp2`, `go-hpack`,
`python-hpack`, `raw-data`).

## Encoder and decoder

```@docs
PureHTTP2.HPACKEncoder
PureHTTP2.HPACKDecoder
PureHTTP2.encode_headers
PureHTTP2.decode_headers
PureHTTP2.set_max_table_size!
PureHTTP2.encode_table_size_update
```

## Dynamic table

```@docs
PureHTTP2.DynamicTable
```

## Low-level primitives

These helpers are exported for users who need to work at a level
below the encoder/decoder — for example, an implementation building
its own custom framing or needing to compute Huffman-encoded lengths
before allocating.

```@docs
PureHTTP2.huffman_encode
PureHTTP2.huffman_decode
PureHTTP2.huffman_encoded_length
PureHTTP2.encode_integer
PureHTTP2.decode_integer
PureHTTP2.encode_string
PureHTTP2.decode_string
```
