---
id: INFRA-054
type: bug
severity: high
title: Make release-record failure fatal to a deploy
source: audit finding FND-0014 — DEC-037
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0014-release-pruning-lists-configmaps-it-may-not-list.md`
**Decision:** `DEC-037`

## The defect

`cmd_deploy.ml:484-507` records the release and treats a failure as a warning:

```ocaml
match Sol_cli_release_store.record_plan ~ctx:cluster ~apply_mode:… plan with
| Error msg -> Printf.eprintf "warning: could not record release: %s\n%!" msg
| Ok () -> (… prune …)
```

Observed live: the release pointer could not be patched, and the deploy still
printed `Done. 1 service(s) deployed.` The pointer kept naming an older release
(`r-6d35ecdb…` while recording `r-33d8e08d…`), while `sol rollback` and retention
anchor on it.

## The fix (per DEC-037)

A deployment is not successful unless the authoritative release state is recorded.
Applying the workload and recording the release are **one outcome**:

1. a record failure makes `sol deploy` exit nonzero, with no successful completion
   line;
2. the message names what could not be recorded, and says the workloads may already
   be running — so an operator does not redeploy unnecessarily;
3. no `warning:` followed by `Done.` for this path.

Deliver this **independently of** `INFRA-055`. The guarantee must hold whether or
not the write mechanism is fixed: a deploy that cannot record must fail, whatever
the cause (denied RBAC, full API server, version skew).

## Acceptance criteria

1. When the release record cannot be written, `sol deploy` exits nonzero and does not
   print a successful completion.
2. When it can be written, behaviour is unchanged, and the pointer names the release
   just applied.
3. A regression case where **workload application succeeds and only the record write
   fails**, asserting both the nonzero exit and the absence of a success line — the
   case the live run actually hit.
4. The prune failure keeps its current treatment: pruning is genuinely best-effort
   and is not the release identity.

## Note for the implementer

Settle the discrepancy the finding records: the static contract prints
`warning: could not record release: …` on this path, and the live run printed
**no warning at all**, only kubectl's error. `Sol_cli_process.run_ok` does fail on a
non-zero exit, so either the failing apply was not reached through
`record_release_and_prune`, or its output was captured somewhere the console does
not show. Reproduce that before changing the branch, so the fix lands on the real
call path.

## Out of scope

The write mechanism and the RBAC (`INFRA-055`), and the prune/list authorization.

## Landed (2026-09-20)

DEC-037 implemented: a release-record failure is the deployment's failure, and recording happens before the success line. Mutation-verified regression case for application-succeeds/record-fails.

Merged in #394; live-retested against the preserved Run 8 target. See
`internal/qualification/records/2026-09-20-run8-aws.md`.
