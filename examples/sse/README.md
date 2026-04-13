# h2c Server-Sent Events (SSE) example

A minimal HTTP/2 over cleartext TCP (`h2c`) server that emits 5
`data: tick N\n\n` events at 1-second intervals on path `/ticks`,
using the **write-side streaming primitive** `Base.flush(res)`
introduced in PureHTTP2.jl v0.5.0. The handler `flush`es each
event to the wire immediately after producing it, so a streaming
client sees the ticks arrive one by one rather than all-at-once
after the handler returns.

This example is the canonical showcase for `flush(res)`. It is
the companion to the non-streaming
[`../echo-handler/`](../echo-handler/README.md) example — both
are built on `serve_with_handler!`, but only this one
demonstrates mid-handler response emission.

## Files

- `server.jl` — ~45-line SSE tick handler. Emits 5 ticks at
  1-second intervals on `/ticks`; returns a plain 404 on any
  other path.
- No sibling `client.jl` — `curl` serves as the streaming
  client. The existing `examples/echo/client.jl` uses
  `open_connection!`, which blocks until `END_STREAM` and
  returns the full accumulated body; that would receive the
  5-tick response as a single 5-line body after 5 seconds and
  not show the streaming behavior. Curl with `-N` is what
  makes the streaming visible.

## Running

In one terminal, start the server:

```sh
julia --project=. examples/sse/server.jl
```

In another terminal, hit it with curl in streaming mode:

```sh
curl -N --http2-prior-knowledge http://127.0.0.1:8787/ticks
```

Expected output (one line per second, over ~5 seconds total):

```
data: tick 1

data: tick 2

data: tick 3

data: tick 4

data: tick 5
```

curl exits cleanly (status 0) after the fifth tick.

### Why `-N`?

`curl -N` (short for `--no-buffer`) disables curl's output
buffering so each line prints to the terminal as soon as it
arrives. Without `-N`, curl would buffer the entire response
and print all 5 ticks at once — you would see the correct
result but not the streaming behavior.

### Why `--http2-prior-knowledge`?

`--http2-prior-knowledge` tells curl to speak HTTP/2 over
cleartext TCP directly, without first trying HTTP/1.1 with
an `Upgrade: h2c` negotiation. PureHTTP2.jl's server path
expects the client to start with the HTTP/2 connection
preface — this flag matches that expectation. Equivalently,
`--http2-prior-knowledge` can be written as `--http2-prior-knowledge`
(long form) or via `-v --http2-prior-knowledge` if you want
curl's verbose output.

## `flush(res)` vs SSE

It is worth being precise about the distinction:

- **`flush(res)`** is a **generic HTTP/2 streaming primitive**
  provided by PureHTTP2.jl. It emits whatever response body
  bytes the handler has accumulated in `res.body` as DATA
  frame(s) on the wire **immediately**, clears the buffer,
  and returns. It knows nothing about SSE, event formats, or
  `text/event-stream` semantics.

- **Server-Sent Events (SSE)** is a **client-side protocol**
  layered on top of HTTP. The server sends one or more
  `data: <payload>\n\n` text blocks over a single HTTP
  response with `content-type: text/event-stream`. Clients
  parse each double-newline-terminated block as one event.
  SSE is what browsers' `EventSource` constructor reads.

This example combines the two: it uses `flush(res)` (the
generic streaming primitive) to push events formatted as SSE
(the client protocol). The `content-type: text/event-stream`
header and the `data: tick N\n\n` body format are SSE; the
`flush(res)` + `sleep(1.0)` loop is HTTP/2 streaming.

If you are serving something other than SSE (chunked uploads
with progress, long-polling, gRPC server-streaming methods)
you would use the same `flush(res)` primitive with a different
content-type and a different body format.

## Changing the tick count or making it infinite

The handler body has a literal `for i in 1:5` loop. To change
the number of ticks, edit the range. For an indefinite stream
that runs until the client disconnects or the server is
stopped, change it to:

```julia
for i in 1:typemax(Int)
    write_body!(res, "data: tick $i\n\n")
    flush(res)
    sleep(1.0)
end
```

Use Ctrl-C on curl to stop receiving events, then Ctrl-C on
the server terminal to stop the server.

## See also

- [`../echo-handler/`](../echo-handler/README.md) — the
  simpler non-streaming handler example that uses only the
  M8 buffered API (`set_status!` / `set_header!` /
  `write_body!` / return).
- [`../echo/`](../echo/README.md) — the low-level
  manual-frame-loop example, preserved as a pedagogical
  showcase of what `serve_with_handler!` abstracts away.
- [`docs/src/handler.md`](../../docs/src/handler.md) —
  full reference for the handler API including the
  "Streaming" section with `Base.flush(::Response)`
  semantics, lazy HEADERS commit rules, and the error-path
  contract under streaming.
