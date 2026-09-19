---
id: INFRA-033
type: bug
severity: high
title: A run directory can be pruned underneath a live command, killing it mid-teardown
source: HARDEN-002 Run 5 attempt 2, 2026-09-19 — a cloud destroy died mid-teardown
  and left the target provisioned and billing
---

**Depends on:** None.

**Related:** INFRA-031 (the same run's phase reporting), HARDEN-002 (the run).

## What happened

`sol cloud destroy` on a real target died with an uncaught exception while tearing
the target down:

```
$ 'terraform' ... 'destroy' -auto-approve ... (platform destroy)
sol: internal error, uncaught exception:
     Sys_error("/home/…/.local/share/sol/runs/cloud-destroy-20260919T001717Z-23151/platform-destroy.log:
               No such file or directory")
```

Its run directory had **been deleted while the command was running**. The
teardown aborted at that point with the EKS cluster, four `m6i.xlarge` nodes and
a Multi-AZ RDS instance still provisioned, so the account kept billing until the
destroy was re-run (which then completed normally). Nothing about the failure
was specific to teardown: any long command can be killed the same way.

## Root cause

`Sol_cli_run_log.create` keeps the newest `keep` (default **20**) run directories
and deletes the rest. Its exclude list contained **only the run being created**:

```ocaml
(runs_to_prune ~exclude:[ run_id ] ~all_run_ids:existing ~keep ());
```

The module already guarded against a run pruning *itself* (its own comments
explain that history), but not against pruning **another run that is still
alive**. So once the runs directory exceeded 20 entries, any new `sol`
invocation could delete the directory of a command that was still executing —
and the victim's next phase write failed with an uncaught `SysError`, because
`write_file` opened the path with no check that the directory still existed.

This is easy to hit in normal use: cloud apply/destroy run for tens of minutes,
and a single `sol` invocation is enough to trigger the eviction. It was hit here
by running the offline lifecycle harness (which invokes `sol` repeatedly) while a
live teardown was running — a completely ordinary thing to do.

## Remediation

1. **Never prune a run whose process is still alive.** The run id already ends in
   the owning pid (`<prefix>-<timestamp>-<pid>`), so liveness is directly
   checkable; `create` now excludes every live run, not just itself.
   `run_is_live` is conservatively `false` where liveness cannot be established
   (a platform without `/proc`, or an id whose tail is not a pid), which leaves
   pruning exactly as it behaved before on those platforms.
2. **Never let a lost phase log kill a running command.** `write_file` and
   `append_phase_log` now recreate the run directory if it is gone. Pruning no
   longer targets live runs, but a directory can still disappear underneath a
   long command, and losing a log is not a reason to abort a teardown.

## Acceptance criteria

- A run whose owning process is alive is never returned by `runs_to_prune`, and
  `create` passes every live run in its exclude list.
- Dead runs beyond `keep` are still reclaimed, so the runs directory stays bounded.
- An id whose tail is not a pid, or an id with no tail, is never treated as live.
- On a platform without `/proc` the previous pruning behaviour is unchanged.
- Writing a phase log whose run directory has been removed recreates the
  directory instead of raising.
- Offline tests pin the live-run regression (added: `run_is_live` cases and
  `runs_to_prune` "never prunes a live run").

**Demo/example coverage:** No user-facing example change; this is run-log
bookkeeping. The behaviour is observable as "a long `sol` command is no longer
killed by another `sol` command".

**TypeScript parity:** No language-parity impact.
