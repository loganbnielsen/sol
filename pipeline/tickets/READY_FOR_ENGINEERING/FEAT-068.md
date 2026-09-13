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

1. **`sol cloud init` writes the destination into the target it creates.** A target Sol creates comes out with `kube_context` already set, so an ordinary user never learns the field exists. When the target file is hand-written rather than generated, print the exact line to add instead of rewriting the user's file.
2. **Teardown must not mutate the operator's kubeconfig.** `cli/sol/bin/cmd_cloud_tf.ml` reads `kubectl config current-context` to name the context it just created, and runs `kubectl config use-context` to restore the operator's. Both are ambient-state mutations. Use a **scoped kubeconfig** instead: write the teardown credentials to a temp file and hand them to the child via `KUBECONFIG` (or `--kubeconfig`), so the operator's own ambient state is never touched. This is also what removes FEAT-063's recorded exception to its own grep criterion.
3. `sol cloud init` may still **print** a context-switching command for the human's own `kubectl`. It must not make Sol depend on it.

## Acceptance criteria

- A target created by `sol cloud init` comes out with `kube_context` already set.
- No Kubernetes operation in the CLI decides its destination from `current-context`, and none mutates it — including `sol cloud init`'s own access to a cluster it is tearing down.
- FEAT-063's `kubectl` grep criterion (only the adapter, plus the local-dev carve-out) holds with no `cmd_cloud_tf` exception.

## Notes

Split from FEAT-063 on 2026-09-13 so the binding change could land on its own; the scoped-kubeconfig plumbing is the destination channel FEAT-063 introduces, which is why this depends on it rather than landing first.
