---
id: FEAT-071
type: feature
severity: medium
source: FEAT-070 review follow-up, 2026-09-14 — settle attempt semantics and tighten identity/error handling
---

**Depends on:** FEAT-070.

**Related:** FEAT-069 (the release identity a deployment points at), DEC-018.

Make the deployment event mean *one deploy attempt*, and hold FEAT-069's
identity and fail-closed discipline across the deployment path.

## Work

1. **Attempt semantics.** A deployment event is one invocation, whether or not
   the apply succeeded: mint the id when the attempt starts, write the immutable
   event when it finishes, with `outcome = applied | apply_failed`. A failed
   apply still records an event (and still exits non-zero); the release record is
   written only on success. Code and prose must not mean different things by
   "attempt" and "successful apply".

2. **Keep identity types typed inside the domain object.** `Sol_cli_deployment.t`
   carries `deployment_id : Sol_cli_deployment_id.t` and
   `release_id : Sol_cli_release_id.t`; `to_string`/`of_string` happen at the
   JSON/YAML/table boundary only. `configmap_name` can then no longer receive a
   malformed id, and `validate` no longer re-parses what construction already
   established.

3. **Fail closed on corrupt records.** A listing that finds an unparseable or
   invalid `sol-deployment-<id>` record returns an error naming it, rather than
   silently dropping it and printing the rest as if that were the whole history.
   Apply the same rule to the release reader (`Sol_cli_release`), which currently
   skips malformed records — one policy for both stores.

4. **Don't advertise a join that does not exist.** Push the OBS-037 Loki marker
   only when the authoritative deployment record was persisted (and the apply
   succeeded). A marker whose `deployment_id` has no record is worse than no
   marker.

## Acceptance criteria

- A failed apply leaves a `sol-deployment-<id>` record with `outcome=apply_failed`
  and the attempted `release_id`; `sol deployments` shows it (a `STATUS` column).
- A successful apply leaves `outcome=applied`, and only then is the release
  record written.
- `Sol_cli_deployment.t` exposes `Deployment_id.t` / `Release_id.t`, not strings;
  `of_json` rejects a malformed id rather than accepting it.
- `sol deployments` and `sol releases` return an error, not a short list, when a
  matching record is corrupt.
- No Loki marker is pushed when the deployment record write fails.

## Notes

The four changes come from the FEAT-070 review. The attempt model is the larger
one; the typing and fail-closed fixes are independent and small.

## Completion notes (2026-09-14)

All four review changes landed. The release derivation/render/store path is
still untouched — this is deployment-event work only.

### 1. Attempt semantics

`Sol_cli_deployment` now carries `outcome = Applied | Apply_failed`. Both command
paths mint the deployment id *before* the apply and record the immutable event
once, when the attempt finishes:

- `cmd_up.run_apply` and `cmd_deploy.run_apply` no longer exit before recording:
  the apply result is captured, the event is written with the outcome, and only
  then does a failure exit non-zero.
- The release record (`sol-release-<id>` plus pointer) is written only in the
  success branch — "the release exists" is a claim a failed attempt cannot make.
- `sol deployments` gained a `STATUS` column (`applied` / `apply_failed`).
- `cmd_deploy` grew `run_plan_result`; `run_plan` (used by dry-run/emit) wraps it
  and keeps the old exit-on-failure behaviour.

### 2. Typed identities

`Sol_cli_deployment.t` carries `deployment_id : Deployment_id.t` and
`release_id : Release_id.t`. `of_plan` stores them directly; `to_json` /
`to_configmap_json` / `format_table` call `to_string` at the boundary; `of_json`
calls `of_string` and returns an error for a malformed id. `validate` is now the
name direction only, because constructing `t` already established the ids, and
`configmap_name` can no longer receive a malformed id.

### 3. Fail closed

`Sol_cli_deployment.parse_kubectl_list` and `Sol_cli_release.parse_kubectl_list`
both return `Error "… history contains an invalid record: <name>: <reason>"` when
a matching ConfigMap is missing data, unparseable, or fails `validate`.
`sol deployments` / `sol releases` surface that error and exit 1 instead of
printing a partial list. The release reader changed too, so both stores share one
policy; `test_release`'s reader case flipped from "skips" to "fails closed".

### 4. No orphan marker

`cmd_deploy.run_apply` pushes the OBS-037 Loki marker only when the deployment
record was persisted **and** the apply succeeded (the marker's message says
"deployed"). A failed record write now suppresses the marker entirely rather than
advertising a `deployment_id` the store does not contain.

### Acceptance criteria

- Failed apply records `outcome=apply_failed` with the attempted `release_id` and
  still exits non-zero — the model test pins the event; the command flow is
  structural (record, then exit). There is no cluster-level test of a failed
  apply.
- Successful apply records `outcome=applied`, and the release record is written
  only then — the command flow's success branch.
- `Sol_cli_deployment.t` exposes typed ids; `of_json` rejects a malformed id —
  `test_deployment` "rejects a bad deployment id" / "rejects a bad release id".
- Corrupt records error, not a short list — `test_deployment` / `test_release`
  "fails closed on corrupt records".
- No marker when the record write fails — the push is gated on `recorded`.

### Verification

`dune build`, `dune fmt` (clean), full `dune test` green. `test_deployment` now
covers attempt/outcome, typed-id rejection, fail-closed reads and the STATUS
table; the golden-path smoke also asserts the listed attempt's status is
`applied`.
