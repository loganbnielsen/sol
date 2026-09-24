# FND-0038 — The consumer-group-removal guard reads unreadable deploy state as "no previous groups", and its rationale contradicts `offset_reset = Earliest`

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` (BUG-045, 2026-09-24: unreadable record refuses, failed write fails the deploy before "Done", message corrected; fake-kubectl tests + mutation checks)
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `BUG-045`
- **Invariant:** the guard's own purpose, and BUG-025's comment in the same file:
  ignoring the state result *"let the check run against nothing while looking healthy."*
- **Evidence class:** `STATIC`

## What is established

`sol deploy` and `sol up` refuse to proceed when a previously deployed consumer group is
missing from the plan, unless `--confirm-group-change` is passed
(`cmd_deploy.ml:104`, `cmd_up.ml:64`). The previous set comes from
`load_deployed_groups` (`sol_cli_deployment_state.ml:25-41`):

```ocaml
| Error _ -> []
| Ok r when r.Sol_cli_process.exit_code <> 0 -> []
```

Unreachable cluster, forbidden read, and "never recorded" all become "no previous
groups", so `removed = []` and **the guard passes silently**. The write side was fixed
by BUG-025 but only to a warning (`save_deployed_groups`, `:43-68`), so a failed record
also disables the next deploy's guard. BUG-025's comment describes exactly the failure
the read path still has.

**The rationale is also wrong for Sol's own consumers.** The refusal text says a
re-added group *"will be consumed from the latest offset … silently skipping any
backlog."* Every Sol consumer config sets `offset_reset = Kafka.Consumer.Earliest`
(`kafka_service.ml:337, 396`; `kafka_service_retry_topics.ml:404, 439`). A re-added group
resumes from its committed offset if the broker still retains it. Otherwise it starts
from the **earliest** retained offset, which means reprocessing and duplicate side
effects, not skipping. The guard exists for a real hazard but describes a different
one, which misleads the operator deciding whether to pass `--confirm-group-change`.

## Impact

Medium. A safety gate that silently opens exactly when the cluster is misbehaving, and
explains the risk it guards against incorrectly.

## Remedy shape

Distinguish NotFound ("no recorded state" — first deploy, legitimately empty) from
every other failure, which must stop the deploy with the reason. Make a failed
`save_deployed_groups` fail the deploy's outcome, or at least be recorded as a state the
next read treats as "unknown", not "empty". Correct the message to the real hazard
(reprocessing from committed or earliest offset).

## Related

BUG-025; AUDIT-028 / REFAC-031 / REFAC-041 (the guard's history); FND-0024 (same collapse).
