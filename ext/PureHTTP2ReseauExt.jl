# Milestone 7.5: Reseau.jl TLS backend.
#
# This package extension adds three constructor-style helpers to
# PureHTTP2.jl when both PureHTTP2 and Reseau.jl are loaded in the same
# environment:
#
#   PureHTTP2.reseau_h2_server_config(; cert_file, key_file, kwargs...) -> Reseau.TLS.Config
#   PureHTTP2.reseau_h2_client_config(; kwargs...)                       -> Reseau.TLS.Config
#   PureHTTP2.reseau_h2_connect(address; kwargs...)                      -> Reseau.TLS.Conn
#
# All three pre-populate `alpn_protocols = PureHTTP2.ALPN_H2_PROTOCOLS`
# (`== ["h2"]`) unless the caller overrides it explicitly.
#
# Design note: the M5 pattern for OpenSSL.jl is a **mutator** —
# `PureHTTP2.set_alpn_h2!(ctx::OpenSSL.SSLContext)` modifies a mutable
# C-backed context in place. Reseau.jl's `TLS.Config` is an
# **immutable** Julia struct (Reseau v1.0.1 `src/5_tls.jl:171`),
# and `alpn_protocols` is defensively `copy()`-ed at construction
# (`src/5_tls.jl:240`). A mutator signature on an immutable struct
# is structurally impossible, so the Reseau helpers are
# **constructor-style** instead. See
# `specs/009-reseau-tls-backend/contracts/README.md` Section 2 for
# the full symmetry-break rationale.
#
# This extension is the M7.5 unblock for server-side h2 over TLS:
# Reseau.jl binds `SSL_CTX_set_alpn_select_cb` at
# `src/5_tls.jl:725-732` in v1.0.1, which is the exact upstream
# gap in OpenSSL.jl that blocked PureHTTP2.jl's `serve_connection!`
# from running as an h2 TLS server at M5/M6/M7. The M6
# `upstream-bugs.md` entry for OpenSSL.jl is now marked
# `worked-around via Reseau.jl`.

module PureHTTP2ReseauExt

using PureHTTP2
using Reseau

# Helper: merge kwargs while allowing the caller to override
# `alpn_protocols`. Returns a NamedTuple suitable for splatting
# into Reseau.TLS.Config or Reseau.TLS.connect.
function _h2_kwargs(kwargs)
    kwdict = Dict{Symbol, Any}(kwargs)
    if !haskey(kwdict, :alpn_protocols)
        kwdict[:alpn_protocols] = PureHTTP2.ALPN_H2_PROTOCOLS
    end
    return (; kwdict...)
end

function PureHTTP2.reseau_h2_server_config(; cert_file, key_file, kwargs...)
    return Reseau.TLS.Config(;
        cert_file = cert_file,
        key_file  = key_file,
        _h2_kwargs(kwargs)...,
    )
end

function PureHTTP2.reseau_h2_client_config(; kwargs...)
    return Reseau.TLS.Config(; _h2_kwargs(kwargs)...)
end

function PureHTTP2.reseau_h2_connect(address::AbstractString; kwargs...)
    return Reseau.TLS.connect(address; _h2_kwargs(kwargs)...)
end

end # module PureHTTP2ReseauExt
