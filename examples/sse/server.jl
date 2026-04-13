# h2c Server-Sent Events example using serve_with_handler! +
# Base.flush(res) — the write-side streaming primitive (v0.5.0).
# Emits 5 `data: tick N\n\n` events one second apart, flushing
# each to the wire immediately. See README.md for full docs.
#
# Run:  julia --project=. examples/sse/server.jl
# Test: curl -N --http2-prior-knowledge http://127.0.0.1:8787/ticks

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
        sleep(1.0)       # wait a second before the next tick
    end
end

function main(; host = IPv4("127.0.0.1"), port::Int = 8787)
    server = listen(host, port)
    @info "SSE example listening" url="http://$(host):$(port)/ticks"
    try
        while isopen(server)
            sock = accept(server)
            @async try
                serve_with_handler!(sse_tick_handler, HTTP2Connection(), sock)
            catch err
                @warn "connection terminated" exception=(err, catch_backtrace())
            finally
                close(sock)
            end
        end
    finally
        close(server)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
