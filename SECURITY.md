# Security Policy

## Supported versions

PureHTTP2.jl follows [Semantic Versioning](https://semver.org/). Security
fixes are applied to the latest released minor version on the `main`
branch. Older minor versions are not backported.

| Version | Supported          |
| ------- | ------------------ |
| 0.3.x   | :white_check_mark: |
| < 0.3   | :x:                |

## Reporting a vulnerability

If you believe you have found a security vulnerability in PureHTTP2.jl
— for example, a crash triggered by a malicious peer, an HPACK decoder
flaw, a flow-control accounting bug exploitable for denial of service,
or any deviation from [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html)
or [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html) with
security impact — **please do not open a public GitHub issue**.

Instead, report it privately through GitHub's
[private vulnerability reporting](https://github.com/s-celles/PureHTTP2.jl/security/advisories/new)
workflow. This creates a draft advisory visible only to the
maintainers.

Please include:

- A description of the vulnerability and its impact.
- A minimal reproduction (Julia version, PureHTTP2.jl version,
  environment, and a script or test case if possible).
- Any known mitigations or workarounds.

## Disclosure process

- Acknowledgement within **7 days** of the report.
- Initial assessment within **14 days**.
- Coordinated disclosure: a fix is prepared on a private branch, a
  patch release is cut, and the GitHub advisory is published together
  with the release notes in [`CHANGELOG.md`](CHANGELOG.md).

## Scope

In scope:

- The `PureHTTP2` module and its two package extensions
  (`PureHTTP2OpenSSLExt`, `PureHTTP2ReseauExt`).
- Protocol conformance bugs in the frame layer, HPACK codec, stream
  state machine, connection lifecycle, and flow-control accounting.

Out of scope:

- Vulnerabilities in upstream dependencies (`OpenSSL.jl`, `Reseau.jl`,
  `libnghttp2`). Please report those to their respective projects.
  Known upstream issues tracked by PureHTTP2.jl are listed in
  [`upstream-bugs.md`](upstream-bugs.md).
- Issues in the `test/interop/` cross-test environment that do not
  affect the shipped library.
