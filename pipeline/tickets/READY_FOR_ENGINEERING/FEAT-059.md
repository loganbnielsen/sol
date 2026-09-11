---
id: FEAT-059
type: feature
severity: medium
source: DEC-020 (deployment destinations are explicit)
---

**Depends on:** DEC-020.

**Continued by:** FEAT-063 (binding every operation to the destination). **Related:** DEC-016, FEAT-058, FEAT-061.

A target names its destination — the mechanism Sol uses to reach a cluster — and the same-cluster lint compares that destination rather than a descriptive name.

**Boundary — destination is not scope.** This ticket decides *where* an operation runs; it must not decide *what* it touches. Scope — which services, workers or functions are being deployed — resolves above the Kubernetes seam, in discovery and the plan, and is modelled separately in FEAT-061. Concretely: `sol_cli_kubectl` learns *where*, never *what*. A kubectl helper that knows which service is being deployed has already conflated the two axes, and would make changing one silently affect the other. Resolution belongs at that seam for the destination only; do not let it grow into a selection mechanism.

**Sol writes the destination; the user chooses a target.** This must not become a pass-through for kubectl plumbing. Sol already provisions the cluster (`sol cloud init` creates it and writes the kubeconfig), so **Sol knows the context name it created** — it should record that in the target when it provisions, and the user should never have to hand-write an ARN to deploy to a cluster Sol made. The field is a target-level fact, not user homework:

- **Provisioned clusters:** `sol cloud init` writes the resolved context into the target. Zero user input, explicit by construction.
- **Bring-your-own clusters:** the user names a context, ideally the friendly name from their `kubeconfig` rather than a raw ARN, and Sol verifies it resolves — failing closed if it does not.
- **Never:** a fallback to whatever `kubectl` happens to be pointing at, and never a *required* hand-written field for the common path.

Explicit does not mean manual. If deploying to a Sol-created cluster requires the user to know what a kube-context is, this ticket has failed its intent even if the invariant holds. (The *writing* half of that is FEAT-063; this ticket makes the field exist and be checked.)

**Inspectable is not the same as authorable.** Storing the destination in the YAML must not make the YAML the user-facing API. The intended surface stays:

```
sol cloud init prod
sol deploy payments --env prod
```

A target summary should read as a target, not as kubectl output — provider, region, cluster, and whether Kubernetes is reachable — with the raw context available only when asked for (FEAT-062). That `sol cloud init` writes the field is the mechanism; a user having to read or write it is the failure mode.

## What this delivers

1. **`Sol_cli_kube_destination`** — `{ context; kubeconfig }`, `of_context` failing closed on an empty or whitespace-only context with an explanation rather than a fallback, the `k3d-sol-local` carve-out, and the argument shapes every operation will use: `--context` for kubectl, `--kube-context` for helm, `KUBECONFIG` in the child environment.
2. **`kube_context` on the target** — the field plus its key variant, both key mappings, the setter case, `target_empty` and `merge_target`, so it parses, merges through overlays and round-trips like any other target field.
3. **`destination_of_target`** — fail-closed resolution from a target, and `destination_identity` for comparison.
4. **The lint compares destinations.** `validate_no_same_cluster` no longer reads `cluster_name`: two fields describing one property would be two sources of truth for exactly what that check protects — it could verify one field while the deploy landed via the other. Destinations are compared together with their kubeconfig, since one context name in two kubeconfigs can be two clusters, and a target whose destination cannot be resolved is skipped here because it fails closed at deploy time instead.

A kube-context is a client-side handle, not an identity: it bundles a cluster reference, credentials and optionally a namespace, and can be renamed without the cluster changing. So keep three things distinct — the **target** (identity), the **destination configuration** (`kube_context = "sol-prod-us-west-2"`), and the **resolved physical cluster** (whatever that context points to). DEC-020 trusts the configured destination; proving physical identity is FEAT-058. Context names are usually compound (`arn:aws:eks:…`), so this is not the same thing as `cluster_name`, and the two are not required to agree textually.

## What moved to FEAT-063

Threading the destination through the operations themselves. FEAT-063 also carries the abstraction-boundary criterion (`sol cloud init` writing the field), the removal of the ambient reads, and the docs.

**Until FEAT-063 lands, nothing consumes this field yet.** Deploys still inherit `kubectl`'s ambient context, exactly as before — this ticket makes the destination *expressible, comparable and verifiable*; it does not yet make it *binding*. Do not read the presence of `kube_context` as the invariant being in force.

## Acceptance criteria

- A target can name its destination, and the value parses, merges through overlays and round-trips like any other target field.
- `destination_of_target` returns the configured context, and fails closed with a message naming the field when none is set.
- The destination type refuses construction from an empty or whitespace-only context, and that refusal is distinguishable from "no destination configured".
- The same-cluster lint refuses two environments that share a destination, naming both environments and the context; and does **not** refuse two environments whose destinations differ, even when their `cluster_name` values are identical — the case that breaks if the lint goes back to reading `cluster_name`.

## Notes

Do not build cluster-identity enforcement here. That is FEAT-058: this removes a hidden *input* to the destination; it does not make an explicitly named destination *correct*.
