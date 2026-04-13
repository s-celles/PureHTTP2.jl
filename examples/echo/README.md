# h2c echo example

A minimal HTTP/2 over cleartext TCP (`h2c`) echo server and client
built on PureHTTP2.jl public API. The server replies to every request
with status `200` and a response body equal to the request body.

## Files

- `server.jl` — listens on `127.0.0.1:8787`, drives the protocol frame
  loop manually and echoes each completed request.
- `client.jl` — sends a `POST /echo` request with a caller-supplied
  body via `PureHTTP2.open_connection!` and prints the response.

## Running

In one terminal, start the server:

```sh
julia --project=. examples/echo/server.jl
```

In another terminal, run the client:

```sh
julia --project=. examples/echo/client.jl "hello, echo"
```

Expected client output (headers order may vary):

```
status  = 200
headers = [(":status", "200"), ("content-type", "text/plain; charset=utf-8"), ("content-length", "11"), ("server", "PureHTTP2.jl-echo-example")]
body    = hello, echo
```

## Why the server does not use `serve_connection!`

[`PureHTTP2.serve_connection!`](../../src/serve.jl) drives the HTTP/2
protocol plumbing (preface, SETTINGS, PING, GOAWAY, flow control) but
does not expose an application-level request handler hook. To echo a
request body, `server.jl` inlines the same frame-read loop and, after
each `process_frame` call, scans `conn.streams` for streams whose
request is fully received (`headers_complete && end_stream_received`)
and emits the response via the public `send_headers` / `send_data`
helpers.

This file is preserved as an **intentional low-level pedagogical
showcase** of the manual frame-loop pattern — a useful teaching
artifact for readers who want to understand what HTTP/2 server
plumbing looks like in raw form.

**For application code, prefer the high-level handler API.**
[`../echo-handler/`](../echo-handler/README.md) is the sibling
example that produces the same observable output using
`PureHTTP2.serve_with_handler!` (added in v0.4.0), which
dispatches a request-handler callback once per completed request
stream and handles all the protocol plumbing internally. See
[`docs/src/handler.md`](../../docs/src/handler.md) for the full
reference.
