using Documenter
using PureHTTP2

makedocs(;
    modules = [PureHTTP2],
    sitename = "PureHTTP2.jl",
    authors = "Sébastien Celles",
    format = Documenter.HTML(;
        canonical = "https://s-celles.github.io/PureHTTP2.jl",
        edit_link = "main",
    ),
    pages = [
        "Home" => "index.md",
        "Frames" => "frames.md",
        "HPACK" => "hpack.md",
        "Streams" => "streams.md",
        "Connection" => "connection.md",
        "Flow control" => "flow-control.md",
        "Interop parity" => "nghttp2-parity.md",
        "TLS & transport" => "tls.md",
        "Server handler" => "handler.md",
        "Client" => "client.md",
        "API Reference" => "api.md",
    ],
    checkdocs = :exports,
    warnonly = false,
)

if get(ENV, "GITHUB_ACTIONS", nothing) == "true"
    deploydocs(;
        repo = "github.com/s-celles/PureHTTP2.jl",
        devbranch = "main",
        push_preview = true,
    )
end
