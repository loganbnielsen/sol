---
id: INFRA-099
type: bug
severity: medium
title: An intermittent provider-roots guard failure in a full fast-check run reads a partial provider list
source: local pre-push gate, twice on 2026-10-03 (INFRA-060 branch) and once reproduced under load
---

**Depends on:** None.

**Found while:** pushing `INFRA-060/transport-establishment`. It is not caused by that
branch's content: the same commit and the same class pass `0/98` repeatedly (see *What was
observed*, item 2).

## Problem

`internal/ci/run_fast_checks.sh` (`verify.sh static`) fails intermittently on
`internal/ci/check_provider_roots.sh` — and on `internal/ci/test_provider_roots.sh` — in a
run whose verbatim message shows the guard reading a **partial provider list**. Isolated
runs of every piece pass.

## What was observed (verbatim)

1. `git push` of `321b4ae8`, 2026-10-03T05:20Z — the mutation test, whose output is
   discarded, so the failing branch is unidentified:

```
FAIL     0s  internal/ci/test_provider_roots.sh
verify static: 1/98 members failed

──── FAIL: internal/ci/test_provider_roots.sh
  [OK]   two providers with every role
  [FAIL] a registered provider with no directory is on paper (S11) (expected pass, got fail)

fast checks: verification classes FAILED
fast checks: finished in 176s
error: failed to push some refs to 'github.com:loganbnielsen/sol.git'
```

   An earlier `git push` (`b86fec06`, 05:10Z) failed the same class in the same way, but its
   per-member block was above the captured tail; only `verification classes FAILED` and
   `finished in 159s` are recorded for it.

2. What passes on the same content, in the same worktree:

| probe | result |
|---|---|
| `bash internal/ci/test_provider_roots.sh`, 30 consecutive runs | `failures=0/30` |
| `bash internal/tooling/scripts/verify.sh static` (three runs, two on `b86fec06`'s content) | `verify static: 0/98 members failed` |
| `bash internal/ci/run_fast_checks.sh` (build, `@ci-unit`, `@ci-lifecycle`, always, static, `verify_test.sh`) | pass, twice |
| the full runner with the pre-push environment reproduced (hook-style stdin ref list; `unset $(git rev-parse --local-env-vars)`; `GIT_PREFIX=` and `GIT_EXEC_PATH` present) | `verify static: 0/98 members failed` |

3. **Reproduced under load**, and this time the failing member was the guard itself, so its
   message survives (`for j in 1..8: while :; do :; done &`, then
   `bash internal/ci/run_fast_checks.sh`):

```
FAIL     0s  internal/ci/check_provider_roots.sh
verify static: 1/98 members failed

──── FAIL: internal/ci/check_provider_roots.sh
check_provider_roots: platform/cloud/aws/ is not a registered provider (Sol_cli_provider.all) and not one of: modules delivery
check_provider_roots: providers must mirror each other by role (DEC-046 rule 4)

fast checks: verification classes FAILED
fast checks: finished in 80s
```

   3 of 4 runs at that load passed (`0/98`); 1 failed. 8 of 10 runs overall were green.

## What the message implies

The message fires only when `providers` — `cut -f1` of the rows `providers.sh` returned —
does not contain `aws`, **and** the guard's `no registered provider has roots` branch did not
fire, so `real > 0`: some provider it did read had a `platform/cloud/<provider>/` directory.
Only `aws` was reported unregistered while `gcp` was not, so **the list it read was `gcp`
alone — missing its first entry**. The tree in that run was the real repository, which is
correct by construction.

So the failure is in **reading the provider list**, not in the tree:

- `sol_provider_rows` returns `SOL_PROVIDERS` if set, otherwise executes
  `_build/default/cli/test/print_providers.exe` and trusts any non-empty output — there is no
  shape check on the rows, and no check that the list is complete;
- `cli/test/print_providers.ml` prints `Sol_cli_provider.all` in order, one
  `<name>\t<status>` line each, so a list beginning at `gcp` cannot come from that program's
  own logic — it is a partial or corrupt read.

**Hypothesis, not yet tested:** `internal/ci/check_ocamlformat.sh --all` is a member of the
same parallel class and runs `opam exec -- dune fmt --preview`, so a `dune` process is live
while other members execute and read artifacts under `_build` — including the printer this
guard depends on. The class is the only place this has been seen, and load makes it likelier.

## Remediation

1. **First, make the failure legible.** `test_provider_roots.sh`'s `expect` runs the guard
   with `>/dev/null 2>&1`, so its message is discarded exactly when it matters (observation
   1 has no cause for that reason alone). Capture and print it on mismatch, as
   `internal/ci/test_qualification_transport_check.sh` already does.
2. **Then stop trusting a partial read.** Give `sol_provider_rows` a shape check — every
   non-empty line `<name>\t<status>`, and at least one provider — that fails closed with its
   own message instead of handing the loop a shorter list. That converts an intermittent,
   mis-attributed failure into a deterministic one, whatever the underlying cause.
3. **Then test the dune-in-the-class hypothesis**: run the class with
   `check_ocamlformat.sh` serialized (or excluded) under the same load, and see whether the
   failure disappears.
4. Until it is fixed this is a **local-gate flake only**: GitHub CI's `test` job is the
   authoritative gate, and the documented one-off bypass is `SOL_SKIP_HOOKS=1`. If it
   recurs in CI — where it bounces a green PR — it is no longer local and should be raised
   in severity.

## Not claimed

No root cause is claimed beyond "the provider list read was partial". Items 2 and 3 are the
experiments that would settle it; item 1 is what makes any recurrence attributable.
