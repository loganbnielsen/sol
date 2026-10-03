---
id: INFRA-099
type: bug
severity: medium
title: Under pipefail the provider-roots guard's membership test returned a match as a miss
source: local pre-push gate, twice on 2026-10-03 (INFRA-060 branch) and once reproduced under load
---

**Depends on:** None.

**Premise (verified 2026-10-03, while implementing this):** the ticket's working claim — an
intermittent guard failure whose message implies a partial provider list — was wrong about the
cause and right about the symptom: the list was never partial, and the guard's *membership
test* reported a match as a miss. The failure did not recur in 8 further class runs on an
unloaded machine (`verify.sh static`, `0/100` each), which is consistent with the measured rate
and the load-sensitivity of the mechanism below.

**Found while:** pushing `INFRA-060/transport-establishment`. It is not caused by that
branch's content: the same commit and the same class pass `0/98` repeatedly (see *What was
observed*, item 2).

## Problem

`internal/ci/run_fast_checks.sh` (`verify.sh static`) fails intermittently on
`internal/ci/check_provider_roots.sh` — and on `internal/ci/test_provider_roots.sh` — in a
run whose verbatim message names a registered provider as unregistered. Isolated runs of every
piece pass.

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

## Root cause (established 2026-10-03)

The provider list was correct and complete in every run. The *membership test* reported a match
as a miss. The guard read the rows into `providers`, then asked, for each directory under
`platform/cloud/`:

```bash
if ! printf '%s\n' $providers | grep -qx "$name"; then
  echo "check_provider_roots: platform/cloud/$name/ is not a registered provider ..."
```

Under `set -o pipefail` (which the guard sets), that pipeline returns **non-zero when `grep`
matched**, if `printf` is still writing when `grep -q` exits on its first match: `grep -q`
closes its stdin, the writer dies of `SIGPIPE`, and `pipefail` promotes status 141 to the
pipeline's status. `! 141` is true, so a registered provider is accused of being unregistered.

Deterministic with an input large enough that the writer is still writing:

```
$ bash -c 'set -o pipefail; printf "%s\n" $(seq 1 200000) | grep -q 1'; echo $?
141                       # grep matched on line 1; printf got SIGPIPE
$ bash -c 'set -o pipefail; printf "%s\n" $(seq 1 200000) | grep -q 999999'; echo $?
1                         # no match: grep's own status, printf ran to completion
```

At the guard's own size (three tokens), 20000 iterations under eight CPU hogs:

```
printf "%s\n" aws gcp byo | grep -qx aws     ->  status 141: 10, status 0: 19990
```

A herestring and process substitution on the same input return the reader's own status (0 in
three runs each), so the pipe is the entire problem.

**This explains every observation:**

- the accused provider is the one whose own line *matched first* — the first token, `aws` —
  because that match is what ends `grep` and strands the writer; a later provider is accused
  only when the writer still holds its later lines;
- `real > 0` and no per-provider message, because the directory walk never failed: the guard's
  first loop saw a clean tree, and only the second loop's membership test lied;
- the mutation test's case 2 failed while case 1 passed: case 2's list has one more token, so
  one more write is stranded after `grep` exits — a wider window on the same race;
- load sensitivity: under load the writer is descheduled between `grep`'s exit and its next
  write, which is exactly when the signal lands.

`cut -f1` and `awk` were the other two subprocesses between the rows and the verdict; the
investigation also found that `sol_provider_status`'s `awk` failure produced an *empty* status,
which the first loop treats as "on paper" — a transient tool failure could therefore silently
**pass** a provider that declares a root but has no directory. That is fail-open, and the fix
closes it.

## The fix

`internal/ci/providers.sh` and `internal/ci/check_provider_roots.sh`:

1. **The rows are validated before anything is judged.** `provider_rows_parse` accepts only
   non-empty `<name><TAB><root_status>` rows, with a status from the printer's vocabulary
   (`present`, `not_applicable`, `not_implemented`), no space in a name, and no duplicate
   provider. Anything else is refused with its own message and the rows printed, instead of
   being judged.
2. **The verdict is computed from those rows and the filesystem with shell builtins only.**
   Membership is a `case` test over the parsed names, the status lookup is an array index, and
   the directory name is a parameter expansion, so no `grep`, `awk`, `cut` or `basename` stands
   between a tree and a verdict. The only subprocess left is the printer itself, whose failure
   already fails closed with "could not read the provider list".
3. **The mutation test surfaces the guard's output on a mismatch** and gained the adversarial
   cases this defect needed.

## Adversarial verification

The new expectations were run against the **pre-fix guard from `origin/main`** and against the
fixed one. Each row is one invocation over the same fixture tree; the last row is the defect
itself, deterministically:

| probe | pre-fix | fixed |
|---|---|---|
| a well-formed list | exit 0 | exit 0 |
| a partial list (`gcp` row only) | exit 1 (fail-closed) | exit 1 (fail-closed) |
| space-separated fields | **exit 0 — silently misparsed, judged "on paper: azure not_implemented"** | exit 1, refused |
| unknown `root_status` | **exit 0 — silently accepted** | exit 1, refused |
| empty provider name | **exit 0 — silently accepted** | exit 1, refused |
| duplicate provider | **exit 0 — "3 provider(s)"** | exit 1, refused |
| whitespace-only list | exit 1, misleading message | exit 1, refused |
| **well-formed list, with `grep`/`awk`/`cut`/`basename` on `PATH` all failing** | **exit 1 — a registered provider accused because a helper could not run** | **exit 0 — verdict unchanged** |

`internal/ci/test_provider_roots.sh` now carries 19 expectations: the 13 behavioural cases as
before, 5 refusal cases for the shapes above, and the hostile-`PATH` case last — which fails
against the pre-fix guard (the first refusal case fails there too, which is how the new test was
confirmed to detect the defect rather than merely pass beside it).

Local gates on the change: `run_fast_checks.sh` (build, `@ci-unit`, `@ci-lifecycle`, both verify
classes and `verify_test.sh`), `check_no_comments` over the three files, and `verify.sh always`.
A guard-level before/after loop (600 invocations of each guard against the same tree, under
eight hogs) saw **0 failures on both**: the per-call rate is ~0.05 %, so that loop cannot
separate the two, and the mechanism, the construct-level measurement and the hostile-`PATH` case
are what carry the verification. This null result is the honest record of what the loop showed.

## Remediation

1. **Make the failure legible** — done: `test_provider_roots.sh` captures the guard's output and
   prints it on a mismatch, so a recurrence names its cause.
2. **Stop trusting a partial read** — done, and extended: rows are validated (shape, status
   vocabulary, no duplicates, non-empty) and a validation failure refuses with its own message,
   which also removes the `awk`-status fail-open.
3. **Test the dune-in-the-class hypothesis** — answered, and refuted: `check_ocamlformat.sh`,
   the only class member that runs `dune`, does not touch the printer
   (`stat -c '%i %s %Y'` unchanged across 600 samples spanning the member's run), and no class
   member writes to `_build` or to the real tree. The interference was inside the guard.
4. **Local-gate framing** — unchanged and still true: GitHub CI's `test` job is the
   authoritative gate. Nothing here needs `SOL_SKIP_HOOKS=1` any more, and a recurrence in CI
   would now report its own cause instead of an unexplained member failure.

## Follow-up

The same `producer | grep -q` construct survives in four other guards, two of them fail-open
(`check_ocamlformat.sh` can pass a required check while `dune fmt` reports drift). Filed as
`INFRA-101` with the mechanism, the measured rate and the per-site remediation, rather than
expanding this ticket's scope.

## Completion notes

- Ticket moved to `DONE` in the last commit on this branch.
- **Demo / example coverage:** none applies — CI guard internals, not something an app author
  reads or runs.
- **Language parity (DEC-022):** no impact — CI tooling, not a framework convention or an
  application-facing capability.
- **Residual:** the fix is verified by mechanism and by the deterministic hostile-`PATH` case,
  not by reproducing the original intermittent failure at the guard level (600 invocations
  produced none). If it recurs, `test_provider_roots.sh` now prints the guard's message and the
  shape of the list it read.
