module PureHTTP2OpenSSLExt

# Milestone 5: optional OpenSSL.jl package extension.
#
# Provides the single method `PureHTTP2.set_alpn_h2!(::OpenSSL.SSLContext)`
# that converts a user-facing `Vector{String}` of ALPN protocol
# identifiers into the RFC 7301 §3.1 wire format (length-prefixed
# concatenation) and registers it on the TLS context via OpenSSL.jl's
# `ssl_set_alpn`.
#
# This extension loads automatically when both PureHTTP2 and OpenSSL are
# present in the same environment (Julia's `Base.get_extension`
# mechanism). When OpenSSL is not loaded, `PureHTTP2.set_alpn_h2!` exists
# as a generic function with zero methods and calling it throws
# `MethodError` — constitution Principle I's "no runtime OpenSSL dep"
# guarantee.
#
# NOTE: this helper is client-role only. Server-side ALPN selection
# requires `SSL_CTX_set_alpn_select_cb`, which OpenSSL.jl does not
# yet bind — see `upstream-bugs.md`.

using PureHTTP2
using OpenSSL

function PureHTTP2.set_alpn_h2!(ctx::OpenSSL.SSLContext,
                            protocols::Vector{String} = ["h2"])
    # RFC 7301 §3.1: each protocol is a length-prefixed byte sequence,
    # with the length stored in a single byte (so names are bounded
    # at 255 bytes).
    buf = IOBuffer()
    for name in protocols
        nbytes = ncodeunits(name)
        if nbytes == 0
            throw(ArgumentError("ALPN protocol name must not be empty"))
        elseif nbytes > 255
            throw(ArgumentError("ALPN protocol name '$name' exceeds 255 bytes"))
        end
        write(buf, UInt8(nbytes))
        write(buf, name)
    end

    OpenSSL.ssl_set_alpn(ctx, String(take!(buf)))
    return ctx
end

end # module PureHTTP2OpenSSLExt
