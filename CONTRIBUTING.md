# Contributing to Sol

Sol is Apache-2.0 — see [`LICENSE`](LICENSE).

## Not accepting outside contributions yet

**The project is not currently accepting pull requests**, and that is deliberate rather than an oversight: the terms on which outside code is accepted are still being settled (below), and accepting a contribution under the wrong terms permanently restricts what the project can do with its licence.

What is welcome in the meantime:

- **Issues.** Bug reports with a reproduction, design critique, and "this was confusing" are genuinely useful.
- **Security reports.** Please report these privately rather than in a public issue.
- **Questions.** If you are building on Sol and something is unclear, that is a documentation bug worth reporting.

If you have already prepared a change, tell us through an issue rather than letting it sit — we would rather say whether it is something we can take, and under what terms, than have you guess.

## Contributor terms (to be settled before any contribution is accepted)

Two mechanisms are on the table, and the choice is not cosmetic:

- **DCO sign-off** (`git commit -s`) — a per-commit *origin statement*: you certify you created the work, in whole or in part, or otherwise have the right to submit it under this project's licence. Minimum friction, and what most projects use. It does **not** grant permission to relicense the contribution.
- **CLA** — a signed agreement that does grant that permission, which is what makes it possible to change the project's licence later (for example tightening it to prevent a reseller), and what every notable relicensing has relied on.

The distinction is worth stating plainly because it is easy to conflate: a sign-off is an *origin statement, not a rights grant*. And the difference only matters *before* code lands — after a handful of contributors it is not realistically reversible without tracking each of them down. That is why the choice is being settled first rather than deferred, and why no contribution will be accepted until it is.

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
