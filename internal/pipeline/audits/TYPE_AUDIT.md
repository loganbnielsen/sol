# OCaml Type Audit — abstract identities to the serialization edge

This audit checks **one** rule, and nothing else, so a single pass can actually
cover its material:

> **Parse at the boundary, keep the abstract type in the middle, serialize at
> the boundary.** A value whose type is abstract for a reason — an identity, a
> resolved name — must not become a `string` before the function that actually
> writes it out.

The failure mode is quiet: nothing breaks at compile time. A
`~release_id:string` parameter accepts an identity, a label, a user's `--release`
argument, or `""` equally, and the type system stops helping one layer early.
This bit FEAT-071 (`push_deploy_events`), and the same shape is likely elsewhere.

**Scope — keep it small.** Only the types that exist *because* they are abstract:

- `Sol_cli_release_id.t`
- `Sol_cli_kubernetes_name`'s resolved names

Add a type to the list when it appears; do **not** widen this audit into
"prefer records to strings" or general API style — that is
`STYLE_AUDIT_FINDINGS.md`, and widening this one would make its pass too large
to finish honestly.

## Method

Inventory every conversion site for each abstract type:

```
rg -n 'Sol_cli_release_id\.(to_string|of_string)' cli/
rg -n 'Sol_cli_kubernetes_name\.' cli/
```

Classify each site in two passes — do not stop at the first pass, because the
whole failure mode is that an early `to_string` looks local:

1. **boundary** — the value is written to YAML/JSON, a Kubernetes label, an
   object name, a LogQL selector, or a logfmt field; or it is read back from one
   of those. Fine by definition.
2. **premature** — an internal function converts to `string` and passes the
   string *down*, so a callee can no longer tell an identity from any other
   string. File a ticket (see the quality bar below).

Then check the reverse direction: a record whose field holds an identity. Decide
whether the record is a **domain object** (the field should be the abstract
type) or is itself the **serialized form** (a `string` is fine, because it *is*
the edge). State which in the ticket; do not leave it ambiguous. Precedent:
`Sol_cli_release.t` is the serialized artifact, with its `Release_id.t` field
kept abstract until the record is written out.

## Ticket quality bar

A finding names: the abstract type, the function that erases it, and the
function that should be the serialization edge. A finding without a named edge
is not actionable. Severity is `low` unless the erasure can also *validate*
(the bug is accepting an unvalidated string), in which case `medium`.

## Findings

Findings are ticketed as `TYPE_AUDIT-<n>` and appended here.

- **2026-09-14 — `cmd_deploy.push_deploy_events`.** It takes
  `~deployment_id:(Sol_cli_deployment_id.to_string …)` and carries the `string`
  into `Sol_cli_deploy_event.t`, so both the fan-out and the event record stop
  distinguishing a deployment id from any other string. The edge is the logfmt
  payload inside `Sol_cli_deploy_event`. Filed as `TYPE_AUDIT-078`.
  *Fixed 2026-09-14:* `push_deploy_events` and `Sol_cli_deploy_event.t` now carry
  `Deployment_id.t` / `Release_id.t`; `to_string` happens only in the logfmt
  field set, the message body, and the stream labels the pusher builds.
  *(The deployment id and its record were removed with deployment-attempt
  persistence, #1331; the release id remains.)*

- **2026-10-04 — `Sol_cli_up_execution.service_execution`.** Resolved workload
  namespace/name types are erased into strings in an internal execution record
  before image build/push and rollout. The serialization edges are kubectl argv
  construction and terminal formatting. Filed as [TYPE_AUDIT-079](../tickets/READY_FOR_ENGINEERING/TYPE_AUDIT-079.md)
  in the [37-principle review](2026-10-04_37_principles_review.md).
