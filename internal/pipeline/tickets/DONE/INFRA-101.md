---
id: INFRA-101
type: bug
severity: medium
title: A grep -q reader at the end of a pipe reports a false result under pipefail
source: INFRA-099 root cause (2026-10-03), reproduced while fixing it
---

**Depends on:** None.

**Related:** `INFRA-099` (the instance this was found in), `check_ocamlformat.sh` and
`check_gcloud_interface.sh` (where a false result can *pass* a check).

**Premise (verified 2026-10-03, while implementing this):** all four sites still carried the
construct at the branch base (`b9130fbe`), each with the direction recorded below. The same
search found a fifth site in the same harness (`test_cloud_lifecycle_offline.sh:2118`, a
REFAC-115 fixture assertion), fixed here as well; no other `grep -q`-in-a-pipeline remains in
any of the four guards. The mechanism is `INFRA-099`'s established one and was not
re-investigated.

## Problem

Under `set -o pipefail`, `producer | grep -q <pattern>` returns **non-zero when grep
matched**, if the producer is still writing when `grep -q` exits on its first match: the
producer dies of `SIGPIPE` (status 141) and `pipefail` promotes that to the pipeline's
status. A guard that writes `if ! cmd | grep -q ...; then <report a violation>; fi` then
reports a violation that does not exist, and one that writes
`if cmd | grep -q ...; then <report a violation>; fi` can skip a violation that does exist.
With a small input it is intermittent and load-sensitive; with a large input it is
deterministic.

## Evidence

Deterministic, with an input large enough that the producer is still writing:

```
$ bash -c 'set -o pipefail; printf "%s\n" $(seq 1 200000) | grep -q 1'; echo $?
141                       # grep matched on line 1; the producer got SIGPIPE
$ bash -c 'set -o pipefail; printf "%s\n" $(seq 1 200000) | grep -q 999999'; echo $?
1                         # no match: grep's own status, producer ran to completion
```

The construct at the size the guards actually use (three tokens), 20000 iterations under
eight CPU hogs:

```
printf "%s\n" aws gcp byo | grep -qx aws     ->  status 141: 10, status 0: 19990
```

Both alternatives are unaffected (three runs each, large input, status 0): a herestring
(`grep -q 1 <<<"$text"`) and process substitution (`grep -q 1 < <(…)`). Only the pipe form
reports 141.

## Where it was

| site | direction of a false non-zero |
|---|---|
| `check_ocamlformat.sh:22` (`printf '%s\n' "$preview" \| grep -qF "$EXEMPT"`) | the exempt-path refusal is skipped |
| `check_ocamlformat.sh:29` (`printf '%s\n' "$preview" \| grep -q '^Promoting '`) | **fail-open**: the required format check passes while `dune fmt` reports it would promote a file. `$preview` is the whole preview, so this producer is the one most likely to still be writing |
| `check_gcloud_interface.sh:22` (`printf '%s\n' "$gcp_access_fn" \| grep -qF "\"$flag\""`) | **fail-open**: a flag Sol passes and gcloud rejects is not reported |
| `check_gcloud_interface.sh:26,50,67` | a present interface, key or flag is reported missing |
| `context/test_cloud_lifecycle_offline.sh:2023` (`find … \| grep -q .`) | platform files are reported newer than the terraform stub when none are |
| `context/test_cloud_lifecycle_offline.sh:2118` (`grep -A3 … \| grep -q …`) | **fail-open**: a fixture that could not be put back on final-snapshot retention is not detected |
| `context/check_ticket_move.sh:76` (`printf '%s\n' "$SUBJECTS" \| grep -qiE …`) | a ticket-move declaration is reported absent, so the guard refuses a PR that did declare itself part |

`grep -q <pattern> <file>` (no pipe) is not affected — the four other `grep -q` calls in
`check_gcloud_interface.sh` read files directly and are safe.

`INFRA-099` was the first instance: `check_provider_roots.sh` accused a *registered*
provider's directory of being unregistered, ~0.05 % of calls under load, because
`printf … | grep -qx` reported the match as a miss. It is fixed there by deciding membership
with a bash `case` and validating the rows before judging anything.

## What changed (2026-10-03)

Every decision kept its pattern semantics exactly; the producer left the pipeline, so no
consumer's exit can be conflated with the producer's death:

- **`check_ocamlformat.sh`** — `--all` tests the preview with `case`: `*"$EXEMPT"*`, the same
  substring test `grep -qF` made, and `"Promoting "* | *$'\n'"Promoting "*`, the same
  line-start test `grep -q '^Promoting '` made. A promotion or exempt path can no longer be
  skipped by a signal.
- **`check_gcloud_interface.sh`** — the three `printf … | grep` tests became `case` substring
  tests, and `flag_documented` became `[[ "$help_text" =~ $pattern ]]` with the *same* ERE
  (`(^|[^-[:alnum:]])$1([^-[:alnum:]]|$)`), so a help text that documents a flag cannot be read
  as not documenting it.
- **`context/check_ticket_move.sh`** — the declaration test is
  `[[ "${SUBJECTS,,}" =~ $declares_part ]]` over a lowercased copy of both sides, which is the
  `-i` the pipeline had, with the same ERE.
- **`context/test_cloud_lifecycle_offline.sh`** — both sites capture the producer's output and
  test it with a builtin. The DEC-050 "did a Terraform run write into Sol's assets?" scan moved
  into `internal/ci/lib/stray_terraform_state.sh`, whose contract is explicit: exit 0 with the
  offending paths, or exit 1 with `could not scan` when `find` itself fails — the harness
  reports that as a failure instead of reading an unscannable tree as clean. The REFAC-115
  fixture assertion captures `grep -A3 …` and tests it with `case`.

The helper is an extraction, not a refactor for its own sake: the scan had no seam to test apart
from the harness run itself. `internal/ci/lib/stray_terraform_state.sh` is now covered by
`internal/ci/test_stray_terraform_state.sh`, which the static class discovers and runs,
including the `could not scan` branch. The harness *is* run — `dune build @ci-lifecycle`,
declared in `cli/test/dune`, which the fast checks and CI invoke — so that rule now declares the
new library as a dependency; the missing dependency was caught by running the class locally, and
the class passes with it.

## Verification

Each new case was first run against the **pre-fix guards** (the tree at `b9130fbe`, with only
the new test files overlaid) to confirm it fails there for the reason under test:

| probe | pre-fix | fixed |
|---|---|---|
| `--all`: a clean 370 KB preview | passes | passes |
| `--all`: a promotion on the *first* line of a 370 KB preview | **accepted — the fail-open** | refused |
| `--all`: a promotion at the *end* of a 370 KB preview | refused | refused |
| `--all`: the exempt path in a 370 KB preview | accepted | refused, by name |
| `--all`: `dune fmt` itself failing | refused | refused |
| gcloud: a clean fixture, provider source > 64 KB, help text > 64 KB | **refused with four invented "does not document" reports** | passes |
| gcloud: that fixture, its access slice also carrying `"--kubeconfig"` | **the `--kubeconfig` report is skipped and a missing-KUBECONFIG report is invented** | refuses naming `--kubeconfig`, invents nothing |
| ticket-move: a > 64 KB subject list whose newest commit declares `(INFRA-901, part A)` | **refused — the declaration did not survive the pipe** | accepted |
| helper: clean tree / new state of each kind / state older than the marker | n/a (extracted) | ignored / reported / ignored |
| helper: a `find` that cannot run | **a mutation that collapses the branch reads it as clean** | refused as unscannable |

The ticket-move pattern translation was checked separately for equivalence: 15 subject strings
(positive, negative, case variants, zero-space and multi-space forms) give **0 mismatches**
between `grep -qiE` and the new test, and the > 64 KB subject list gives `match` for the new
form against `none (rc=141)` for the old one.

Gates: `test_stray_terraform_state.sh`, `test_ocamlformat.sh`, `test_gcloud_interface.sh` and
`test_ticket_move.sh` all pass; `verify.sh always` 0/9; `check_no_comments` clean over the nine
files; and the offline lifecycle harness, which `dune build @ci-lifecycle` runs from the
`_build` copy of the script, passes with the edited check — its `DEC-050: …` section intact,
exit 0 — both as the class and when invoked directly with the built binary.

## Remediation

Applied per the ticket's own options: the reader is off the pipe everywhere, and the decision is
a shell builtin (`case` or `[[ =~ ]]`). Where a producer's failure needed a *new* signal — the
DEC-050 scan — there is now an explicit fail-closed branch rather than trusting `pipefail` to
make a tool failure look like a finding.

## Completion notes

- Ticket moved to `DONE` in the last commit on this branch.
- **Demo / example coverage:** none applies — CI guard and harness internals, not something an
  app author reads or runs.
- **Language parity (DEC-022):** no impact — CI tooling, not a framework convention or an
  application-facing capability.
- The fifth site (`:2118`) is included because it is the same construct in one of the four
  guards this ticket records; no broader sweep of the repository was made.

## Not claimed

No live or production impact: these are CI tooling guards, and most of the failure directions
are a false *refusal* that bounces a green PR or the offline lifecycle suite. The severity is
for the fail-open directions above — a required check, or the offline harness's own fixture
setup, passing while the condition it exists to catch is present.
