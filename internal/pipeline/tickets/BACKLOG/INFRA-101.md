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

## Where it still is

| site | direction of a false non-zero |
|---|---|
| `check_ocamlformat.sh:22` (`printf '%s\n' "$preview" \| grep -qF "$EXEMPT"`) | the exempt-path refusal is skipped |
| `check_ocamlformat.sh:29` (`printf '%s\n' "$preview" \| grep -q '^Promoting '`) | **fail-open**: the required format check passes while `dune fmt` reports it would promote a file. `$preview` is the whole preview, so this producer is the one most likely to still be writing |
| `check_gcloud_interface.sh:22` (`printf '%s\n' "$gcp_access_fn" \| grep -qF "\"$flag\""`) | **fail-open**: a flag Sol passes and gcloud rejects is not reported |
| `check_gcloud_interface.sh:26,50,67` | a present interface, key or flag is reported missing |
| `context/test_cloud_lifecycle_offline.sh:2023` (`find … \| grep -q .`) | platform files are reported newer than the terraform stub when none are |
| `context/check_ticket_move.sh:76` (`printf '%s\n' "$SUBJECTS" \| grep -qiE …`) | a ticket-move declaration is reported absent, so the guard refuses a PR that did declare itself part |

`grep -q <pattern> <file>` (no pipe) is not affected — the four other `grep -q` calls in
`check_gcloud_interface.sh` read files directly and are safe.

`INFRA-099` was the first instance: `check_provider_roots.sh` accused a *registered*
provider's directory of being unregistered, ~0.05 % of calls under load, because
`printf … | grep -qx` reported the match as a miss. It is fixed there by deciding membership
with a bash `case` and validating the rows before judging anything.

## Remediation

Per site, one of:

1. **A shell-builtin test** where the decision is membership: `case " $words " in *" $word "*)`
   (`INFRA-099`'s fix);
2. **The reader off the pipe**: `grep -q <pattern> <<<"$text"`, a real file, or process
   substitution — all return the reader's own status (verified above);
3. **If the pipe stays, no early-exit reader at its end**: `grep -c` reads all input, or
   capture the producer's output into a variable first and test that.

Each fix needs a mutation case that fails when the construct is restored, in the shape
`test_provider_roots.sh` now uses: it runs the guard with a `PATH` whose `grep`, `awk`, `cut`
and `basename` all fail, and requires the verdict to be unchanged.

## Not claimed

No live or production impact: these are CI tooling guards, and most of the failure directions
are a false *refusal* that bounces a green PR or the offline lifecycle suite. The severity is
for the two fail-open directions above — a required check that can pass while the drift it
exists to catch is present.
