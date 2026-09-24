# FND-0047 — On GCP, a cluster-access failure exits without removing the bootstrap access it was handed to remove

- **Classification:** `VERIFIED_DEFECT`, against DEC-040 (the bootstrap window is closed on
  every exit path)
- **State:** `OPEN`
- **First identified:** 2026-09-23, by a second reviewer at `main @ f2e1773`; re-verified at
  `origin/main @ f3e9480b`
- **Derived ticket:** `INFRA-070`, `REFAC-091` (lifecycle port)
- **Evidence class:** `STATIC`

## What is established

`with_cluster_access ?(on_error = Fun.id) ~region outputs f`
(`cli/sol/bin/cmd_cloud_tf.ml:1418-1424`) passes `on_error` to the AWS helper but does
`ignore on_error` on the GCP branch. `gcp_provisioner_kubeconfig` (`:1356-1416`) then
calls `lifecycle_error` (which `exit 1`s) when `gcloud … get-credentials` fails or cannot
run.

Both callers that pass a real `on_error` do so right after enabling bootstrap access:

- install, `:2415` — `~on_error:cleanup_bootstrap_access`;
- destroy, `:2712` — `destroy_platform ~on_error`.

So on GCP, a credential failure at that point (missing impersonation grant, expired ADC,
transient API error) ends the process **with the provisioner still elevated**.

## Why this keeps happening (design note, not the ticket)

`require_terraform_success` and `lifecycle_error` `exit` from deep inside helpers. `exit`
does not unwind, so `Fun.protect` finalizers do not run. The code compensates with
`at_exit` for kubeconfigs and a hand-threaded `on_error` every failing branch must
remember, and this finding is a branch that forgot. `cmd_rollback.ml` already has the
shape that removes the class: the sequence returns a result, cleanup is bracketed with
`Fun.protect`, and only the command edge turns a refusal into an exit. Porting the destroy
and install lifecycles to that shape (`execute ~deps` with terraform/gcloud/aws injected)
would make cleanup impossible to forget, put the exit-code contract in one place, and make
the sequences testable offline, including an Attempt-6 replay (FND-0044).

## Remedy shape

Immediate: honour `on_error` on the GCP branch (call it before `lifecycle_error`, or have
the helper return a result). Structural: the rollback-style port above.

## Related

DEC-040, FND-0021, INFRA-039; FND-0044.
