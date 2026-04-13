# Server handler

PureHTTP2.jl's **high-level server-side entry point**. Dispatches
an application-level request-handler callback once per completed
HTTP/2 request stream so application code never has to touch the
frame layer.

This is the server-side companion to the [client](client.md)
page. The [TLS & transport](tls.md) page documents the low-level
`serve_connection!` entry point that drives the protocol plumbing
without a handler hook — use that when you want to inspect
individual frames or implement a custom dispatch strategy.

## Quick example

The entire server-side logic of an h2c echo server fits in one
short function:

```julia
using PureHTTP2
using Sockets

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

function main(; host = IPv4("127.0.0.1"), port::Int = 8787)
    server = listen(host, port)
    try
        while isopen(server)
            sock = accept(server)
            @async try
                serve_with_handler!(echo_handler, HTTP2Connection(), sock)
            finally
                close(sock)
            end
        end
    finally
        close(server)
    end
end
```

This example is maintained verbatim in
[`examples/echo-handler/server.jl`](https://github.com/s-celles/PureHTTP2.jl/blob/main/examples/echo-handler/server.jl).
The [`examples/echo/`](https://github.com/s-celles/PureHTTP2.jl/blob/main/examples/echo/server.jl)
sibling example shows the same demo implemented by driving the
frame loop manually — a useful reference if you want to
understand exactly what `serve_with_handler!` abstracts away.

## Handler signature

A PureHTTP2.jl handler is any Julia callable accepting two
positional arguments:

```julia
handler(req::Request, res::Response) -> Any
```

The return value is **ignored** — the server auto-finalizes the
response stream when the handler function returns. Handlers
should not return a meaningful value; any side effects on
`res` (status, headers, body bytes) become the outgoing response.

Because the handler is the first positional argument to
[`serve_with_handler!`](@ref), Julia's `do`-block syntax works:

```julia
serve_with_handler!(HTTP2Connection(), sock) do req, res
    set_status!(res, 200)
    write_body!(res, "Hello from PureHTTP2.jl!")
end
```

```@docs
serve_with_handler!
```

## Request

```@docs
Request
request_method
request_path
request_authority
request_headers
request_header
request_body
request_trailers
```

## Response

```@docs
Response
set_status!
set_header!
write_body!
```

## Error handling

When the handler throws an exception,
[`serve_with_handler!`](@ref) catches it — the exception is
**never rethrown** to the caller. The server then:

1. Logs `@warn "handler threw" stream_id=… exception=(err, bt)`
   so you retain the full backtrace.
2. Emits a `RST_STREAM` frame with error code `INTERNAL_ERROR`
   on the affected stream.
3. Marks the associated [`Response`](@ref) as finalized so no
   further mutator calls take effect.
4. Continues the frame loop — other streams on the same
   connection keep being served normally.

This guarantee means your listen loop — typically

```julia
while isopen(server)
    sock = accept(server)
    @async try
        serve_with_handler!(my_handler, HTTP2Connection(), sock)
    finally
        close(sock)
    end
end
```

— survives application bugs. One handler throwing does not kill
the connection for other in-flight requests, and it does not
kill the `@async` task for subsequent requests on the same
connection.

If you want a different error-path response (for example, a
`500 Internal Server Error` HEADERS frame with a JSON body),
catch the exception **inside** the handler and set the response
manually:

```julia
function my_handler(req::Request, res::Response)
    try
        do_some_work(req)
    catch err
        set_status!(res, 500)
        set_header!(res, "content-type", "application/json")
        write_body!(res, "{\"error\":\"$(sprint(showerror, err))\"}")
        return
    end
    set_status!(res, 200)
    write_body!(res, "ok")
end
```

The server only resets the stream with `INTERNAL_ERROR` when the
handler throws **out** of its body — catching internally lets
you shape the wire response however you like.

## Concurrency

Handlers are invoked **sequentially** in stream-close order by
the same task that drives the frame read/write loop. There is no
per-stream `Task`, no write lock on the transport, and no output
queue. If multiple streams on one connection become complete
within the same frame-processing batch (e.g., interleaved
streams 1 and 3), they are dispatched in ascending stream-ID
order.

### Trade-off: blocking handlers stall the connection

A handler that blocks on long-running I/O — a synchronous
database query, an `HTTP.get`, a `sleep` — stalls the entire
connection's frame loop until it returns. Other streams on the
same connection do not make progress until then.

This is a deliberate simplicity trade-off at v0.4.0. For
typical HTTP/2 servers where each connection multiplexes a
handful of requests from one client, the blocking is rarely
observable. If you need concurrent per-stream dispatch, you can
spawn your own `Task` from within the handler and return
immediately — **with the important caveat that you MUST finish
writing the response before the handler returns**, because the
server finalizes the stream on return. Calling `set_status!`,
`set_header!`, or `write_body!` on `res` from a Task that
outlives the handler body is undefined behavior (the response
is already on the wire).

A future milestone may add opt-in per-stream `Task` dispatch as
a pure addition — existing handler code will continue to work
unchanged.

### Cross-connection concurrency

Multiple `serve_with_handler!` calls on **different** connections
may run concurrently from different tasks — there is no global
state, no shared lock. The standard pattern is one
`@async serve_with_handler!(...)` per accepted connection in
your listen loop.

### Invariants on `req` and `res` sharing

- `Request` is immutable, but the backing `HTTP2Stream` is not
  thread-safe. Concurrent access to the same `Request` from
  multiple tasks is UNSAFE in v0.4.0.
- `Response` is mutable. Concurrent mutations from multiple
  tasks are UNSAFE in v0.4.0.
- Both `req` and `res` are valid only for the duration of the
  handler call that received them. Retaining references past
  the return has undefined behavior — the server may remove
  the backing stream from the connection's internal state
  immediately after finalization.

## Streaming

Mid-handler **response-body streaming** is live as of v0.5.0 via
the new `Base.flush(::Response)` primitive. Handlers call
`flush(res)` to push currently-accumulated body bytes to the
wire as HTTP/2 DATA frame(s) **immediately**, without waiting
for the handler function to return. The accumulated buffer is
cleared after each flush, and subsequent `write_body!` calls
start filling a fresh buffer — a natural rhythm for streaming
handlers is `write_body!` → `flush` → compute/sleep →
`write_body!` → `flush` → ...

This unblocks use cases that cannot be expressed with the
buffered-only handler shape:

- Server-Sent Events (SSE) feeds that push updates every second
- Long-running computations that emit progress before completion
- Chunked downloads where the server yields bytes incrementally
- gRPC server-streaming methods (once PureHTTP2.jl grows a gRPC
  adapter in a future milestone)

### Quick streaming example

```julia
using PureHTTP2
using Sockets

function sse_tick_handler(req::Request, res::Response)
    if request_path(req) != "/ticks"
        set_status!(res, 404)
        set_header!(res, "content-type", "text/plain; charset=utf-8")
        write_body!(res, "Not Found\n")
        return
    end

    set_status!(res, 200)
    set_header!(res, "content-type", "text/event-stream")
    set_header!(res, "cache-control", "no-cache")
    set_header!(res, "server", "PureHTTP2.jl-sse-example")

    for i in 1:5
        write_body!(res, "data: tick $i\n\n")
        flush(res)       # push this event to the wire NOW
        sleep(1.0)
    end
end
```

Run the server and hit it with curl in streaming mode:

```sh
curl -N --http2-prior-knowledge http://127.0.0.1:8787/ticks
```

You will see `data: tick 1` through `data: tick 5` arrive one
per second, not all-at-once after 5 seconds. The `-N` flag
disables curl's output buffering so each line prints as soon
as it arrives. This example is maintained verbatim at
[`examples/sse/server.jl`](https://github.com/s-celles/PureHTTP2.jl/blob/main/examples/sse/server.jl).

```@docs
Base.flush(::PureHTTP2.Response)
```

### Lazy HEADERS emission

The **first** call to `flush(res)` on a given response emits
the response HEADERS frame carrying the current `res.status`
and `res.headers` — **before** the DATA frame for the flushed
body. Subsequent flushes emit DATA frames only; HEADERS are not
repeated. This is the only wire-legal ordering per RFC 9113
§8.1 (DATA must follow HEADERS on any stream).

Once HEADERS are on the wire, `set_status!` and `set_header!`
become **no-ops** that log `@warn "Response headers already on
the wire; … is a no-op"`. Handlers that want to mutate status
or headers must do so **before** the first flush:

```julia
function streaming_handler(req::Request, res::Response)
    # ✓ OK: mutate status + headers before any flush
    set_status!(res, 200)
    set_header!(res, "content-type", "text/plain")

    write_body!(res, "chunk-1")
    flush(res)                        # HEADERS + DATA emitted here

    # ✗ NO-OP: HEADERS already on the wire, this logs a @warn
    set_header!(res, "x-late", "too late")

    write_body!(res, "chunk-2")
    flush(res)                        # DATA only (no HEADERS repeat)
end
```

`write_body!` continues to work after a flush — it appends to
the now-emptied buffer so the next flush emits the next DATA
frame.

### Error path under streaming

The [Error handling](#Error-handling) contract is unchanged: if
the handler throws, `serve_with_handler!` catches the exception,
logs `@warn "handler threw"`, and emits `RST_STREAM(INTERNAL_ERROR)`
on the affected stream.

The one clarification for streaming: if the handler has
**already flushed** one or more chunks before throwing, the
wire sequence becomes:

```
HEADERS(:status=200) + DATA(chunk-1) + … + DATA(chunk-N) + RST_STREAM(INTERNAL_ERROR)
```

This is valid HTTP/2. Clients observe a truncated response with
an explicit abort signal. **Bytes already on the wire cannot be
rolled back** — this is inherent to streaming, not a bug. The
connection itself survives (other streams on the same
connection continue to be served normally).

### Future: request-side streaming

The **write side** of streaming ships in v0.5.0 via
`Base.flush(::Response)`. The **read side** — incremental
request-body reads before `END_STREAM` — is still **reserved**
as a forward-compat extension point for a follow-up milestone:

- `Base.read(req::Request, n::Integer) -> Vector{UInt8}` will
  read `n` bytes from the request body incrementally,
  complementing the buffered `request_body(req)` accessor that
  ships today.

When it lands, existing handlers that call `request_body(req)`
will continue to work unchanged — the new method is a pure
addition, not a replacement. Handlers that want incremental
reads will opt in by calling `Base.read` instead.

## See also

- [`examples/echo-handler/`](https://github.com/s-celles/PureHTTP2.jl/tree/main/examples/echo-handler)
  — the worked example sourced for this page.
- [`examples/echo/`](https://github.com/s-celles/PureHTTP2.jl/tree/main/examples/echo)
  — the low-level counterpart that drives the frame loop
  manually.
- [TLS & transport](tls.md) — `serve_connection!` (the
  low-level entry point) and the optional TLS/ALPN backends.
- [Client](client.md) — `open_connection!` (the client-role
  counterpart of `serve_with_handler!`).
