---
id: FEAT-059
type: feature
severity: medium
source: DEC-020 (deployment destinations are explicit)
---

**Depends on:** DEC-020.

**Replaces:** the enforcement half of FEAT-058 (now backlog). Related: DEC-016.

Make the destination a function of the selected target: pass the resolved Kubernetes context (or a scoped `KUBECONFIG`) through every operation, and stop reading or mutating `kubectl`'s current context.

**Boundary — destination is not scope.** This ticket decides *where* an operation runs; it must not decide *what* it touches. Scope — which services, workers or functions are being deployed — resolves above the Kubernetes seam, in discovery and the plan, and is modelled separately in FEAT-061. Concretely: `sol_cli_kubectl` learns *where*, never *what*. A kubectl helper that knows which service is being deployed has already conflated the two axes, and would make changing one silently affect the other. Resolution should be centralised at that seam for the destination only; do not let it grow into a selection mechanism.

**Sol writes the destination; the user chooses a target.** This must not become a pass-through for kubectl plumbing. Sol already provisions the cluster (`sol cloud init` creates it and writes the kubeconfig), so **Sol knows the context name it created** — it should record that in the target when it provisions, and the user should never have to hand-write an ARN to deploy to a cluster Sol made. The field is a target-level fact, not user homework:

- **Provisioned clusters:** `sol cloud init` writes the resolved context into the target. Zero user input, explicit by construction.
- **Bring-your-own clusters:** the user names a context, ideally the friendly name from their `kubeconfig` rather than a raw ARN, and Sol verifies it resolves — failing closed if it does not.
- **Never:** a fallback to whatever `kubectl` happens to be pointing at, and never a *required* hand-written field for the common path.

Explicit does not mean manual. If deploying to a Sol-created cluster requires the user to know what a kube-context is, this ticket has failed its intent even if the invariant holds.

## Scope

**1. Resolve the destination from the target — as a mechanism, not an identity.**

The target schema gains the **mechanism Sol uses to reach** the destination, not the destination's identity:

```ocaml
type kubernetes_destination =
  { context : string
  ; kubeconfig : string option
  }
```

A kube-context is a client-side handle: it bundles a cluster reference, credentials and optionally a namespace, and it can be renamed without the cluster changing. So keep three things distinct — the **target** (identity), the **destination configuration** (how Sol reaches it, e.g. `kube_context = "sol-prod-us-west-2"`), and the **resolved physical cluster** (whatever that context actually points to). DEC-020 says Sol trusts the configured destination and does not prove physical identity; calling this field the target's "Kubernetes identity" would blur precisely the line that keeps FEAT-058 unnecessary.

Context names are usually compound (`arn:aws:eks:…`), so this is not the same thing as `cluster_name`, and the two are not required to agree textually — see the lint criterion below.

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

**6. Inspectable is not the same as authorable.**

Storing the result in the YAML must not make the YAML the user-facing API. The intended surface stays:

```
sol cloud init prod
sol deploy payments --env prod
```

A target summary should read as a target, not as kubectl output — provider, region, cluster, and whether Kubernetes is reachable — with the raw context available only when asked for. That `sol cloud init` writes the field is the mechanism; a user having to read or write it is the failure mode.

## Acceptance criteria

- **A target created by `sol cloud init` comes out with its destination already set.** This is the criterion that tests the abstraction boundary: if it passes, an ordinary user never discovers that this ticket introduced a context field at all.
- **The same-cluster lint (FEAT-057) compares the destination Sol will actually use**, not the descriptive `cluster_name`. Two fields describing the same property are two sources of truth for exactly the thing that lint protects. `cluster_name` stays descriptive, and is not required to agree textually with the context.
- A unit test proves resolution ignores the ambient context: with the machine's current context set to something unrelated, the resolved destination for a target is unchanged.
- Two targets naming different contexts resolve to different destinations, and the resolved context reaches the executed command.
- No Kubernetes operation in the CLI decides its destination from `current-context`, and none mutates it.
- A target that names no context fails closed with a message naming the target and the expected field — no silent fallback to the ambient context.
- The local target continues to work without ambient state.
- Docs updated: the tutorial's cloud section and the self-hosted substrate contract describe target-scoped destinations, and no longer imply "switch context, then run `sol`". Examples show `sol cloud init` then `sol deploy` — never a hand-written context.

## Notes

Do not build cluster-identity enforcement here. That is FEAT-058, and DEC-020 explains why it is a different failure class: this ticket removes a hidden input; it does not make an explicit value correct.
