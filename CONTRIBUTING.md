# Contributing to PureHTTP2.jl

Thank you for your interest in contributing! PureHTTP2.jl is a
pure-Julia implementation of [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html)
and [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html), developed
under the [PureHTTP2.jl constitution](.specify/memory/constitution.md).

## Code of Conduct

This project and everyone participating in it is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are
expected to uphold this code.

## Ground rules

- **Pure Julia only.** `[deps]` in the top-level `Project.toml` must
  remain empty. Optional native integrations (OpenSSL, Reseau) go
  through package extensions under `[weakdeps]` + `[extensions]`.
- **RFC first.** In case of uncertainty, RFC 9113 (HTTP/2) and
  RFC 7541 (HPACK) are the authoritative references. Cite section
  numbers in commit messages, tests, and doc pages when the behavior
  you change is RFC-mandated.
- **Test-driven development.** Write the test before the code. Use
  [TestItemRunner.jl](https://github.com/julia-vscode/TestItemRunner.jl)
  `@testitem` blocks, not bare `@testset`.
- **Reference parity.** When the change touches wire-format behavior,
  add an `Interop:` test in `test/interop/` that cross-validates
  against `libnghttp2` through Nghttp2Wrapper.jl.
- **Semantic Versioning.** Breaking changes bump the minor version
  while `0.x`; post-1.0 they bump the major version.
- **Keep a Changelog.** Every user-visible change must be recorded
  in [`CHANGELOG.md`](CHANGELOG.md) under the `Unreleased` section
  in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
- **Document new features.** New public surface requires a
  corresponding page or section under `docs/src/`. The Documenter
  build must remain warning-free.

## Development setup

Requirements:

- Julia `1.10` or later for the main environment.
- Julia `1.12` or later for `test/interop/` (optional; required only
  if you run cross-tests against `libnghttp2`).

Clone and activate:

```sh
git clone https://github.com/s-celles/PureHTTP2.jl.git
cd PureHTTP2.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## Running the test suite

Main suite:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Interop suite (requires `libnghttp2` via `nghttp2_jll`):

```sh
julia --project=test/interop -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

## Building the documentation

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate(); include("docs/make.jl")'
```

The build **must finish without warnings**. A warning is treated as a
failure and blocks merges.

## Submitting a change

1. **Open an issue first** for anything non-trivial so the approach
   can be discussed before code is written.
2. **Branch** off `main` with a short, descriptive name
   (e.g. `feat/server-push-refuse`, `fix/flow-control-underflow`).
3. **Write tests first.** Add `@testitem` units that fail against
   `main`, then implement the change.
4. **Run tests and build docs** locally. Both must pass with no
   warnings.
5. **Update** [`CHANGELOG.md`](CHANGELOG.md) under `Unreleased` and
   add a `docs/src/` page or section for new features.
6. **Commit** using [Conventional Commits](https://www.conventionalcommits.org/):
   `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, etc.
   Mark breaking changes with a `!` suffix (e.g. `refactor!:`) and
   a `BREAKING CHANGE:` footer.
7. **Open a pull request** against `main`. Describe the motivation,
   cite any relevant RFC sections, and link the issue it resolves.

## Upstream bugs

If you hit a bug in an upstream dependency while working on
PureHTTP2.jl, record it in [`upstream-bugs.md`](upstream-bugs.md)
with a link to the upstream issue and the workaround PureHTTP2.jl
takes, if any.

## Questions

Open a [GitHub Discussion](https://github.com/s-celles/PureHTTP2.jl/discussions)
or a regular issue labelled `question`.
