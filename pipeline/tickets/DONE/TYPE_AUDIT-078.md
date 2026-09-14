---
id: TYPE_AUDIT-078
type: refactor
severity: low
source: docs/audits/TYPE_AUDIT.md first pass, 2026-09-14 — caught in the FEAT-071 review
---

**Depends on:** None.

**Related:** `docs/audits/TYPE_AUDIT.md` (the audit this came from), FEAT-071.

Keep `Deployment_id.t` typed one layer longer in the deploy-marker path.

`Cmd_deploy.push_deploy_events` takes `~deployment_id:string`, and
`Sol_cli_deploy_event.t` carries the deployment id as a `string`. The call site
serializes before the call:

```ocaml
~deployment_id:(Sol_cli_deployment_id.to_string deployment_id)
```

`push_deploy_events` semantically wants a deployment identity, not an arbitrary
string — it is the fan-out that builds the event, not the writer. The
serialization edge is the logfmt field set inside `Sol_cli_deploy_event`, so
`to_string` belongs there and nowhere earlier.

## Work

- Thread `~deployment_id:Sol_cli_deployment_id.t` through `push_deploy_events`.
- Hold `Deployment_id.t` in `Sol_cli_deploy_event.t` (and mli).
- Decide `release` explicitly in the same pass: if the event record is itself
  the serialized form, a `string` is defensible — but say so in the mli instead
  of leaving it implicit.
- Call `to_string` only when building the logfmt payload.

## Acceptance criteria

- No internal API accepts an already-serialized deployment id.
- `Sol_cli_deployment_id.to_string` appears only at the logfmt/serialization
  boundary.
- The marker payload for a given deployment id is byte-identical to today's.

## Completion notes (2026-09-14)

Fixed.

- `Cmd_deploy.push_deploy_events` takes `~deployment_id:Sol_cli_deployment_id.t`;
  the call site no longer serializes it.
- `Sol_cli_deploy_event.t` carries `release_id : Release_id.t` and
  `deployment_id : Deployment_id.t`. Decided explicitly that this record is a
  *domain object*, not the serialized form: `fields`, `message`, and the stream
  labels `cmd_deploy_event.push_event` builds are the edge, and `to_string` is
  called only there. The mli says so.
- `test_deploy_event` builds the fixture with `of_string`-validated ids; the
  logfmt field values (`release`, `deployment_id`) are unchanged, so the marker
  bytes are identical.
- The audit's first finding is marked fixed in `docs/audits/TYPE_AUDIT.md`.
