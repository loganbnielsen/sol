---
id: FEAT-059
type: feature
severity: medium
source: DEC-020 (deployment destinations are explicit)
---

**Depends on:** DEC-020.

**Replaces:** the enforcement half of FEAT-058 (now backlog). Related: DEC-016.

Make the destination a function of the selected target: pass the resolved Kubernetes context (or a scoped `KUBECONFIG`) through every operation, and stop reading or mutating `kubectl`'s current context.

## Scope

**1. Resolve the destination from the target.**

The target schema gains the destination's Kubernetes identity — a `kube_context` (context names are usually compound, e.g. `arn:aws:eks:…`, so this is not always the same as `cluster_name`) and/or a per-target `kubeconfig`. A target must fully determine where it lands.

**2. Pass it explicitly, everywhere.**

Every Kubernetes operation is target-scoped: `kubectl --context <resolved>`, `helm --kube-context <resolved>`, or a scoped `KUBECONFIG` for the process. Prefer the scoped `KUBECONFIG` where practical, because it also removes other environments' credentials from the process — a dev deployment should not have prod credentials available at all.

**3. Remove the ambient reads.**

At the time of filing, these four files consult ambient context state and must stop deciding behaviour from it:

- `cli/sol/bin/cmd_up.ml` — `current_kube_context`, `is_known_local_dev_context`
- `cli/sol/bin/cmd_cloud_tf.ml` — reads `current-context`, and `use-context` (the mutation)
- `cli/sol/lib/sol_cli_port_forward.ml` — `current_kube_context`
- `cli/sol/lib/sol_cli_kubectl.ml` — `config_current_context`

`sol cloud init` may continue to **print** a context-switching command for the human's own `kubectl`; it must not make Sol depend on having run it.

**4. Keep the local carve-out explicit.**

The ephemeral local target may name `k3d-sol-local` literally — it is Sol's own cluster and there is no ambiguity to resolve. Nothing else gets a default.

**5. Fail in a way that teaches.**

When a target names no context, or the resolved context cannot be reached, the error names the target, the context it expected, and what would otherwise have been used — so the change in behaviour is obvious to someone whose habits were built on switching context first.

## Acceptance criteria

- A unit test proves resolution ignores the ambient context: with the machine's current context set to something unrelated, the resolved destination for a target is unchanged.
- Two targets naming different contexts resolve to different destinations, and the resolved context reaches the executed command.
- No Kubernetes operation in the CLI decides its destination from `current-context`, and none mutates it.
- A target that names no context fails closed with a message naming the target and the expected field — no silent fallback to the ambient context.
- The local target continues to work without ambient state.
- Docs updated: the tutorial's cloud section and the self-hosted substrate contract describe target-scoped destinations, and no longer imply "switch context, then run `sol`".

## Notes

Do not build cluster-identity enforcement here. That is FEAT-058, and DEC-020 explains why it is a different failure class: this ticket removes a hidden input; it does not make an explicit value correct.
