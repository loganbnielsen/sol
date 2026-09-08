---
id: AUDIT-017
type: audit-finding
severity: medium
source: project/audits/2026-06-10_audit.md
branch: AUDIT-017/worker-ack-order
worktree: ../sun-AUDIT-017-worker-ack-order
---

Generic `sun new worker` Template Calls `ack()` Before Business Logic

**Depends on:** None.

**Description:** The generic worker template used by `sun new worker <domain>/<name>` (`worker_lib_ml` in `cli/sun/lib/sun_cli_cmd_new.ml`, lines 767–770) calls `ack()` as the second statement in the handler — before any side effect. When a developer adds business logic after the generated `ack()` call, they implement the ack-before-processing anti-pattern: a crash between `ack()` and the side effect permanently loses the message. The workspace-specific template (`ws_worker_ml`, used by `sun new workspace`) was correctly fixed to call `ack()` after the DB insert. The generic template was not updated.

**Impact:** Every service scaffolded with `sun new worker` ships with at-most-once semantics in the handler template, directly contradicting the framework's at-least-once guarantee. There is no compiler or runtime warning.

**Remediation:** Restructure `worker_lib_ml` so `ack()` comes after all side effects, with an explicit comment:
```ocaml
let handle (msg : Message.t) ~ack ~trace_ctx:_ =
  Printf.printf "[{{name}}-worker] received id=%s\n%!" msg.id;
  (* Add side effects here. Call ack() only after all side effects succeed.
     Returning Error without acking causes the message to be retried. *)
  ack ();
  Ok ()
```

