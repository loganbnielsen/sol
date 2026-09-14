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
