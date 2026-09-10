# Contributing to Sol

Sol is Apache-2.0 — see [`LICENSE`](LICENSE). Thanks for considering a change.

## Developer Certificate of Origin (required)

Every commit in a pull request must be **signed off**. The sign-off certifies that
you wrote the change, or otherwise have the right to submit it under this
project's licence:

```bash
git commit -s -m "your message"
```

which appends a trailer:

```
Signed-off-by: Your Name <you@example.com>
```

Commits without one fail CI (`.github/workflows/dco.yml`). Use your real name and
a reachable address; `git config user.name` and `user.email` are what get used.
The full certificate is at <https://developercertificate.org/>.

*Why this is a hard gate:* the sign-off is what keeps the project's licensing
options open — including relicensing a component later if it needs different
terms. It costs nothing now and cannot be reconstructed retroactively once
outside code has landed.

## Before you start

- Build, tests and repository layout: [`.claude/CLAUDE.md`](.claude/CLAUDE.md).
- Where to make common changes: [`docs/architecture/contributing-map.md`](docs/architecture/contributing-map.md).
- The conventions code and docs are held to — including the demo/example coverage
  rule, which requires a runnable example (not only unit tests) for anything that
  changes what an application author writes.

## Checks

```bash
dune build && dune test && dune fmt --preview
```

A pre-commit hook runs the build and unit suites; install it with
`bash cli/platform/local/scripts/install-hooks.sh`. It also enforces that
`pipeline/tickets/` is only edited from the main checkout.

## Trademarks

The "Sol" name and logo are **not** covered by the Apache-2.0 licence — see
[`TRADEMARK.md`](TRADEMARK.md).
