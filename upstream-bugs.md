# Upstream bugs

This file tracks bugs in HTTP2.jl's upstream dependencies and in the
tooling HTTP2.jl relies on for development (Julia itself, Documenter,
TestItemRunner, CI actions, etc.). It is the canonical place to
record a finding when the root cause lives outside this repository —
CLAUDE.md's working rule for contributors and AI assistants is
"if you find an upstream bug create entry in upstream-bugs.md file".

Every entry MUST include:

- **Package**: the upstream package, tool, or service.
- **Issue**: a one-line summary of what goes wrong.
- **Upstream link**: URL to the upstream tracker (issue, PR, or commit).
- **Impact on HTTP2.jl**: what breaks, where it breaks, and whether a
  workaround exists locally.
- **Workaround**: the local workaround, if any, and where it lives
  in this repository.
- **Status**: one of `open`, `fixed-upstream`, `worked-around`,
  `resolved`.

Entries are added in reverse-chronological order (newest first).

## Entries

_(none yet — the file is bootstrapped by Milestone 1.)_
