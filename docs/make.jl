using Documenter
using HTTP2

makedocs(;
    modules = [HTTP2],
    sitename = "HTTP2.jl",
    authors = "Sébastien Celles",
    format = Documenter.HTML(;
        canonical = "https://s-celles.github.io/HTTP2.jl",
        edit_link = "main",
    ),
    pages = [
        "Home" => "index.md",
        "API Reference" => "api.md",
    ],
    checkdocs = :exports,
    warnonly = false,
)

if get(ENV, "GITHUB_ACTIONS", nothing) == "true"
    deploydocs(;
        repo = "github.com/s-celles/HTTP2.jl",
        devbranch = "main",
        push_preview = true,
    )
end
