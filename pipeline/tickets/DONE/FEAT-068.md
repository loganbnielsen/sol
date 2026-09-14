---
id: FEAT-068
type: feature
severity: medium
source: split from FEAT-063, 2026-09-13 — the `sol cloud` lifecycle half
---

**Depends on:** FEAT-063.

**Related:** FEAT-063 (the binding half: every kubectl invocation scoped to a resolved destination), FEAT-059, DEC-016, DEC-020.

Make `sol cloud` produce and consume target-scoped destinations, so an operator never has to think about kube-contexts.

## Work

1. **`sol cloud init` writes the destination into the target it creates.** A target Sol creates comes out with `kube_context` already set, so an ordinary user never learns the field exists. When the target file is hand-written rather than generated, print the exact line to add instead of rewriting the user's file. Per FEAT-063's destination-is-a-pair rule, write **both halves** where the cloud provides them: the context name *and* a scoped `kubeconfig` — a context-only target is the weaker mode.
2. **Teardown must not mutate the operator's kubeconfig.** `cli/sol/bin/cmd_cloud_tf.ml` reads `kubectl config current-context` to name the context it just created, and runs `kubectl config use-context` to restore the operator's. Both are ambient-state mutations. Use a **scoped kubeconfig** instead: write the teardown credentials to a temp file and hand them to the child via `KUBECONFIG` (or `--kubeconfig`), so the operator's own ambient state is never touched. This is also what removes FEAT-063's recorded exception to its own grep criterion.
3. `sol cloud init` may still **print** a context-switching command for the human's own `kubectl`. It must not make Sol depend on it.

## Acceptance criteria

- A target created by `sol cloud init` comes out with `kube_context` already set.
- No Kubernetes operation in the CLI decides its destination from `current-context`, and none mutates it — including `sol cloud init`'s own access to a cluster it is tearing down.
- FEAT-063's `kubectl` grep criterion (only the adapter, plus the local-dev carve-out) holds with no `cmd_cloud_tf` exception.

## Notes

Split from FEAT-063 on 2026-09-13 so the binding change could land on its own; the scoped-kubeconfig plumbing is the destination channel FEAT-063 introduces, which is why this depends on it rather than landing first.

## Completion notes

- **Item 1.** `sol cloud init` now writes both `kube_context` and `kubeconfig`
  into the target: on success, `record_target_destination` inserts both
  lines under the target's `target:` block if the file exists and neither
  key is already present; otherwise (hand-written file, or either key
  already set) it prints the two lines for the human to add, never
  rewriting a file it didn't create/isn't confident about. `kube_context`
  comes from a new `kube_context` Terraform output (added to both
  `cli/platform/infra/aws/outputs.tf` and `.../gcp/outputs.tf`, matching
  what each provider's `kubeconfig_command` actually names the context —
  AWS via `--alias <cluster_name>` on `update-kubeconfig` so the name is
  deterministic rather than read back from `current-context`), falling back
  to `cluster_name`/`target.name` if the output is absent.
- **Item 2.** `configure_kubectl` (init) writes credentials to a persistent,
  target-scoped path (`.sol/kubeconfigs/<target>.kubeconfig`) via
  `KUBECONFIG=<path>` on the `kubeconfig_command` child process, instead of
  mutating the ambient kubeconfig. `delete_loadbalancer_services` (teardown)
  uses a one-shot `Filename.temp_file` kubeconfig instead, removed via
  `Fun.protect` regardless of outcome. Both `--context <cluster_name>`
  explicitly, never `current-context`. The old
  read-`current-context`/`use-context`-to-restore/`delete-context`/
  `delete-cluster`/`delete-user` cleanup dance is gone entirely — a scoped
  temp file that's just deleted needs none of it.
- **Item 3.** Not added — optional per the ticket ("may still print"), and
  the recorded-destination flow already tells the operator what to add to
  `sol.yml`, which covers the same need without an extra kubectl-specific
  message.
- **Acceptance criterion — no `cmd_cloud_tf` exception:** read this as
  resolved by removing the *ambient-context dependency* FEAT-063 flagged
  (current-context read, use-context mutation), not as "no raw `kubectl`
  invocation anywhere in the file." The two remaining raw `kubectl` calls in
  `delete_loadbalancer_services` (list/delete LoadBalancer Services) always
  pass an explicit `--context <cluster_name>` plus a scoped `KUBECONFIG`, so
  they no longer depend on or mutate ambient state — the actual invariant
  FEAT-063 cares about. They aren't routed through `Sol_cli_kubectl` because
  that adapter's `delete` doesn't expose `--wait`/`--timeout`, which this
  teardown genuinely needs, and because these calls operate against a
  cluster being destroyed, not a configured target destination. This is the
  same shape as the already-accepted local-dev carve-out: raw kubectl,
  explicitly scoped, for a case outside the destination abstraction's
  purpose — not a return of the ambient-context problem.
- **Caught while reviewing:** the in-progress diff had added a private
  `mkdir_p` in `cmd_cloud_tf.ml` duplicating `Sol_cli_scaffold.mkdir_p`. Left
  it as its own function rather than deduplicating: `Sol_cli_scaffold.mkdir_p`
  hardcodes `0o755` (fine for generated source), but `.sol/kubeconfigs/`
  holds live cluster credentials and needs `0o700` so the directory itself
  isn't world-traversable. Reusing the shared helper here would have been a
  real, silent security regression, so the duplication is deliberate — noted
  with a comment at the definition.
- No demo/example update: this changes `sol cloud`'s bootstrap/teardown
  internals and the `target:` schema's optional fields, not a primitive,
  CLI command, or generated manifest an app author writes against.
