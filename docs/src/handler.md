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

## Future: streaming

Incremental request-body read and incremental response-body
write are **not shipped in this milestone** per the
Session 2026-04-13 clarification. Two named future extension
points are reserved for a follow-up milestone:

- **Read side**: `Base.read(req::Request, n::Integer) -> Vector{UInt8}`
  for incremental body reads before `END_STREAM`. Complement of
  the buffered `request_body(req::Request)` accessor shipped in
  v0.4.0.
- **Write side**: `flush(res::Response)` for incremental body
  writes — will emit currently-accumulated `res.body` as DATA
  frame(s) immediately, clear the buffer, and return `res` for
  chaining. Complement of the buffered `write_body!(res, bytes)`
  mutator shipped in v0.4.0.

Both are **pure additions** — no symbol shipped in v0.4.0 will
change signature, return type, or semantics when they land.
Existing buffered handlers will continue to work unchanged; only
streaming handlers need to opt in by calling `Base.read` /
`flush` respectively.

If you are planning a handler that will later want streaming
semantics, structure it to call `request_body` exactly once and
to accumulate response bytes via one or more `write_body!` calls.
When the streaming extensions land you will be able to replace
`request_body(req)` with a loop over `Base.read(req, n)` and
insert `flush(res)` calls between `write_body!` calls — no other
changes to the handler shape will be needed.

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
