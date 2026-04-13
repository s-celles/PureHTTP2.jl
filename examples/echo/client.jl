# h2c echo client using PureHTTP2.open_connection!.
#
# Sends a POST request with a body to the echo server in
# `examples/echo/server.jl` and prints the response. The server
# replies with status 200 and a body equal to the request body.
#
# Run (after starting the server):
#     julia --project=. examples/echo/client.jl "hello, echo"
#     julia --project=. examples/echo/client.jl  # default body

using PureHTTP2
using Sockets

function main(body::AbstractString = "hello from PureHTTP2.jl";
              host::AbstractString = "127.0.0.1", port::Int = 8787)
    sock = connect(IPv4(host), port)
    try
        conn = HTTP2Connection()
        authority = string(host, ":", port)
        result = open_connection!(conn, sock;
            request_headers = Tuple{String, String}[
                (":method",       "POST"),
                (":path",         "/echo"),
                (":scheme",       "http"),
                (":authority",    authority),
                ("content-type",  "text/plain; charset=utf-8"),
            ],
            request_body = Vector{UInt8}(body),
        )

        println("status  = ", result.status)
        println("headers = ", result.headers)
        println("body    = ", String(result.body))
    finally
        close(sock)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    body = length(ARGS) >= 1 ? ARGS[1] : "hello from PureHTTP2.jl"
    main(body)
end
