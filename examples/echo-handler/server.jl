# h2c echo server using PureHTTP2.serve_with_handler! — the
# high-level request-handler API introduced in v0.4.0.
#
# This is the high-level companion to ../echo/server.jl (which
# drives the frame loop manually as an intentional low-level
# showcase). Both examples produce byte-identical observable
# output against ../echo/client.jl — the only difference is the
# abstraction level of the server code.
#
# Run:
#     julia --project=. examples/echo-handler/server.jl
#
# Then in another terminal:
#     julia --project=. examples/echo/client.jl "hello, echo"

using PureHTTP2
using Sockets

function echo_handler(req::Request, res::Response)
    body = request_body(req)
    ct = something(request_header(req, "content-type"),
                   "application/octet-stream")

    @info "echo" method=request_method(req) path=request_path(req) bytes=length(body)

    set_status!(res, 200)
    set_header!(res, "content-type", ct)
    set_header!(res, "content-length", string(length(body)))
    set_header!(res, "server", "PureHTTP2.jl-echo-example")
    write_body!(res, body)
end

function main(; host = IPv4("127.0.0.1"), port::Int = 8787)
    server = listen(host, port)
    @info "echo-handler server listening" host=string(host) port=port
    try
        while isopen(server)
            sock = accept(server)
            @async try
                serve_with_handler!(echo_handler, HTTP2Connection(), sock)
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
