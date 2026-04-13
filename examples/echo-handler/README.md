# h2c echo-handler example

A minimal HTTP/2 over cleartext TCP (`h2c`) echo server built on
PureHTTP2.jl's **first-class request-handler API** (`serve_with_handler!`,
added in v0.4.0). The server replies to every request with status
`200` and a response body equal to the request body.

This example is the high-level companion to [`../echo/`](../echo/README.md),
which drives the HTTP/2 frame loop manually as an intentional
low-level showcase. Both produce byte-identical observable output
against the same client — the only difference is the abstraction
level of the server code.

## Files

- `server.jl` — listens on `127.0.0.1:8787`, dispatches every
  completed request to a 5-line `echo_handler(req, res)` callback.
  No frame-layer code at all.
- No sibling `client.jl` — this example reuses
  [`../echo/client.jl`](../echo/client.jl) unchanged. Both servers
  default to `127.0.0.1:8787`, so the same client drives either
  one.

## Running

In one terminal, start the server:

```sh
julia --project=. examples/echo-handler/server.jl
```

In another terminal, run the client (the shared
`examples/echo/client.jl`):

```sh
julia --project=. examples/echo/client.jl "hello, echo"
```

Expected client output (headers order may vary):

```
status  = 200
headers = [(":status", "200"), ("content-type", "text/plain; charset=utf-8"), ("content-length", "11"), ("server", "PureHTTP2.jl-echo-example")]
body    = hello, echo
```

## What the handler does

The entire server-side logic fits in one short function:

```julia
function echo_handler(req::Request, res::Response)
    body = request_body(req)
    ct = something(request_header(req, "content-type"),
                   "application/octet-stream")
    set_status!(res, 200)
    set_header!(res, "content-type", ct)
    set_header!(res, "content-length", string(length(body)))
    set_header!(res, "server", "PureHTTP2.jl-echo-example")
    write_body!(res, body)
end
```

`serve_with_handler!` drives the HTTP/2 protocol plumbing
(connection preface, SETTINGS exchange, PING, GOAWAY, flow
control, frame read/write, per-stream state machine) and invokes
`echo_handler` exactly once per completed request stream with a
read-only `Request` view and a write-accumulator `Response`. When
the handler returns, the server auto-emits the response HEADERS
+ DATA frames with END_STREAM set on the last frame.

If the handler throws, `serve_with_handler!` catches the
exception, logs a `@warn`, and resets the affected stream with
`INTERNAL_ERROR` — the listen loop keeps running and other
streams on the same connection continue to be served.

## See also

- [`../echo/`](../echo/README.md) — the low-level counterpart
  that drives the frame loop manually. Read that README first if
  you want to understand what `serve_with_handler!` abstracts
  away.
- [`docs/src/handler.md`](../../docs/src/handler.md) — full
  reference for the handler API, including the forward-compat
  extension points for a future streaming milestone.
