# Contributing to Sol

Sol is Apache-2.0 — see [`LICENSE`](LICENSE). Thanks for considering a change.

## Contributor sign-off (policy)

Contributions are accepted under the [Developer Certificate of Origin 1.1](https://developercertificate.org/) — a short certificate, not a contract. By signing off, you state for each commit that:

- you created the contribution, in whole or in part, and have the right to submit it under this project's licence; or
- it is based on appropriately-licensed prior work that you have the right to submit under the same licence; or
- it came directly from someone who certified the above and you have not modified it; and
- you understand the contribution and its record are public and may be redistributed under the project's licence.

In practice that means committing with:

```bash
git commit -s -m "your message"
```

which appends:

```
Signed-off-by: Your Name <you@example.com>
```

**This is not currently enforced by CI.** It is stated so contributors know the terms before contributing; enforcement will be added when the project actively solicits outside contributions — alongside the people it governs.

**What a sign-off does and does not do.** It is an *origin statement*, not a rights grant: it certifies you had the right to submit the work under this project's licence. It does **not** give the project permission to relicense your contribution under different terms — that requires a CLA, which is a separate and more consequential decision. Two consequences worth stating plainly: do not sign off on someone else's behalf, and do not add the trailer mechanically. An attestation nobody means is worse than no attestation, because it puts a hollow statement on the record.

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
