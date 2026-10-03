---
id: VERIF-026
type: audit-finding
severity: low
title: check_gcloud_interface reports a missing flag when gcloud produced no usable help
source: observability qualification run 4 — a pre-push hook failure while submitting BUG-124, 2026-10-02
---

**Depends on:** None.

**Related:** VERIF-006, VERIF-024.

This is CI-tooling, not observability; it is filed here and handed to the
verification/CI-tooling workstream rather than fixed inside the observability
change that observed it.

## Observed

`internal/ci/check_gcloud_interface.sh` failed once inside the canonical local
hook (`internal/ci/run_fast_checks.sh`, run by the pre-push hook) with:

```text
──── FAIL: internal/ci/check_gcloud_interface.sh
check_gcloud_interface: gcloud's `container clusters get-credentials` does not document --region, but Sol passes it

verify static: 1/97 members failed
...
fast checks: verification classes FAILED
fast checks: finished in 52s
```

Context: `git push` of `BUG-124/sol-check-exit-vocabulary` from its worktree,
2026-10-02 ~20:35 local (2026-10-03T02:35Z). The same guard had passed minutes
earlier on the branch, and passed on every run since (see below). The documented
`SOL_SKIP_HOOKS=1` bypass was used once for that push; that bypass is local-only
and is **not** the resolution of this finding — the guard's report is
inaccurate and that is the defect.

The guard's message can only come from `flag_documented --region` returning
non-zero, which requires the captured `help_text` to be non-empty (an empty
capture produces "could not read `gcloud ... --help`") and to not contain
`--region`. `command -v gcloud` succeeded in that run, so it was not the
missing-gcloud branch either.

## Investigation

**gcloud's own log for the failing window shows the flag present.** gcloud logs
every invocation under `~/.config/gcloud/logs/<date>/`:

```text
$ ls ~/.config/gcloud/logs/2026.10.02/ | grep '20.3[0-9]'
20.30.38.540833.log  20.31.29.057539.log  20.32.06.915114.log  20.35.05.737623.log
20.35.49.042284.log  20.36.31.603939.log  20.37.10.534606.log  20.38.06.204149.log

$ grep -n -- '--region' ~/.config/gcloud/logs/2026.10.02/20.35.05.737623.log
45:  ... [--location=LOCATION | --region=REGION | --zone=ZONE, -z ZONE]
696: ... --region
709: ... --region=REGION
```

A sweep of **every** gcloud log on disk for a `get-credentials` invocation whose
captured output lacks `--region` returned none. The only anomaly in that window
is a DEBUG-level metadata probe that failed and is captured on stderr:

```text
DEBUG root Failed to check metadata server: <urlopen error [Errno -2] Name or service not known>
```

That line does not remove `--region`, and the guard merges stderr into
`help_text` anyway.

**Not the metadata probe and not VERIF-024.** VERIF-024 governs only the
`CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD` opt-out (`internal/ci/guard_env.txt`
clears it before the guard runs); it does not touch the argv branch or its
output, so it does not explain this. `run_fast_checks.sh` sources only
`scratch_repo.sh` (git-local env vars) and `opam env`, neither of which changes
gcloud's output; after `eval "$(opam env)"` the guard passes and `python3`
resolves to `/usr/bin/python3`.

**Non-reproduction, all passing:**

```text
$ bash internal/ci/check_gcloud_interface.sh            # 10x serial: pass
$ gcloud ... --help | grep -c -- '--region'             # 40x serial, 144x at 12-way concurrency: 3 every time
$ bash internal/tooling/scripts/verify.sh static        # check_gcloud_interface.sh PASS, canonical and worktree
$ bash internal/ci/run_fast_checks.sh                   # full hook in the failing worktree: PASS (164s)
```

No OOM record for the window (`dmesg`), no gcloud component update (SDK files
carry epoch mtimes), and no `gcloud` on any `PATH` entry that shadows the SDK
(`~/.opam/*/bin` has none) or in the repo except the `internal/ci/lifecycle_fakes`
stub, which is only ever reached through a temp `PATH` in a subprocess.

## Conclusion

Unreproduced after roughly 150 direct guard runs, the parallel `verify.sh`
class, and the exact pre-push hook. The failure was therefore a transient
condition in the `gcloud` launcher (the SDK lives under `/home/lbendtly/tmp`),
or some other one-off that produced non-help output — and the guard cannot tell
that apart from "the real help lacks the flag". It collapses *could not run the
CLI* and *ran and the flag is absent* into one verdict, which is the class of
error this repository treats as a defect elsewhere. The one thing that is
certain is the report was misleading: real help documented `--region` at the
same moment.

## Remediation

Make the two failure modes distinct, so a recurrence is diagnosable rather than
merely suspicious:

- Capture gcloud's exit status and raw output. Before reporting a missing flag,
  assert the text is plausibly this subcommand's help (it names
  `gcloud ... clusters get-credentials` and carries a `SYNOPSIS`/`USAGE`
  marker). If it is not, fail with a message that says the CLI produced no
  usable help, and include the exit status and the first lines of what it did
  print.
- Keep the flag-absent message for the case where real help was read and lacks
  the flag.
- Do **not** add a silent retry that papers over the distinction. If a bounded
  retry is wanted for transient launcher failures, it must say it retried and
  what the first attempt produced.
- Do not change the VERIF-024 opt-out behavior or its `guard_env.txt`
  classification.

## Acceptance criteria

- A simulated gcloud that exits non-zero or prints non-help text fails the guard
  naming *that* condition with its exit status and output; it is never reported
  as "does not document <flag>".
- The flag-absent path still fails with the current message when real help lacks
  a flag the guard requires.
- The missing-gcloud branch and the VERIF-024 opt-out path are unchanged.
- `internal/ci/test_gcloud_interface.sh` covers the new unreadable-help path
  with a stub gcloud, and its mutation is caught (the guard fails for the reason
  under test).

**Demo/example:** not applicable — CI tooling only.

**TypeScript parity:** no language-parity impact; this is a shell guard over
Sol's GCP argv, not an application-facing contract.
