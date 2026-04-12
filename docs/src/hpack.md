# HPACK

The HPACK layer implements header compression per RFC 7541. An
[`HPACKEncoder`](@ref HTTP2.HPACKEncoder) and
[`HPACKDecoder`](@ref HTTP2.HPACKDecoder) each maintain a dynamic
table of up to `max_table_size` bytes, sharing a statically-defined
table of 61 common headers. HTTP2.jl's HPACK implementation is
cross-validated in CI against the industry
[`http2jp/hpack-test-case`](https://github.com/http2jp/hpack-test-case)
vector set (four independent producers — `nghttp2`, `go-hpack`,
`python-hpack`, `raw-data`).

## Encoder and decoder

```@docs
HTTP2.HPACKEncoder
HTTP2.HPACKDecoder
HTTP2.encode_headers
HTTP2.decode_headers
HTTP2.set_max_table_size!
HTTP2.encode_table_size_update
```

## Dynamic table

```@docs
HTTP2.DynamicTable
```

## Low-level primitives

These helpers are exported for users who need to work at a level
below the encoder/decoder — for example, an implementation building
its own custom framing or needing to compute Huffman-encoded lengths
before allocating.

```@docs
HTTP2.huffman_encode
HTTP2.huffman_decode
HTTP2.huffman_encoded_length
HTTP2.encode_integer
HTTP2.decode_integer
HTTP2.encode_string
HTTP2.decode_string
```
