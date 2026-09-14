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
