# HTTP2.jl

HTTP2.jl is a pure-Julia implementation of the HTTP/2 protocol
(RFC 9113) and HPACK header compression (RFC 7541), extracted from
the `http2` submodule of
[gRPCServer.jl](https://github.com/s-celles/gRPCServer.jl) and
developed as a standalone, reusable library. Conformance is validated
(from Milestone 4 onward) against
[Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl),
a thin wrapper over the `libnghttp2` reference implementation.

## Project principles

HTTP2.jl follows a [constitution](https://github.com/s-celles/HTTP2.jl/blob/main/.specify/memory/constitution.md)
with five non-negotiable principles:

1. **Pure Julia Implementation** — zero `ccall` into C libraries for
   protocol logic; the `[deps]` block in `Project.toml` is empty.
2. **Test-First with TestItemRunner** — every behavioural change
   follows TDD, wired through `TestItemRunner.jl`.
3. **Specification Conformance & Reference Parity** — wire behaviour
   is validated against `libnghttp2` via Nghttp2Wrapper.jl.
4. **Semantic Versioning & Changelog Discipline** — SemVer, Keep a
   Changelog, Conventional Commits.
5. **Documentation as Code** — every feature ships with warning-free
   Documenter pages; this page is an expression of that gate.

## Status

HTTP2.jl is pre-`0.1.0` development software. The current version is
`0.0.1` (Milestone 1 scaffolding). See
[ROADMAP.md](https://github.com/s-celles/HTTP2.jl/blob/main/ROADMAP.md)
for the planned milestones and
[CHANGELOG.md](https://github.com/s-celles/HTTP2.jl/blob/main/CHANGELOG.md)
for the entries landed so far.

## Reference

- [API Reference](@ref) — types exported at this milestone.
