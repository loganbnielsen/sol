---
id: FEAT-063
type: feature
severity: medium
source: FEAT-059 review 2026-09-11 — the destination field landed; nothing consumes it yet
---

**Depends on:** FEAT-059.

Bind every Kubernetes operation to the target's destination, so the cluster is chosen by the target rather than by whatever `kubectl` happens to be pointing at.

Until this lands, `kube_context` is expressible and checked but **not in force**: deploys still inherit the ambient context.

## Decided: destinations are required parameters

**Decision (2026-09-11): explicit threading, with a *required* parameter.** Not optional, and not the process-global alternative.

The asymmetry is what settles it: **a parameter can be relaxed from required to optional later, but never tightened from optional to required** — tightening breaks every caller. So the strict signature costs nothing now and preserves the option to loosen it if some caller genuinely cannot supply a destination. The reverse choice is permanent.

That also rejects the softer version of the same design: an optional `?destination` leaves unthreaded call sites silently inheriting the ambient context — the hidden input DEC-020 exists to remove, reproduced one layer down where it is harder to see.

**Accepted consequence: every cluster-touching command must resolve a destination**, including diagnostics (`sol logs`, `sol status`, `sol rollback`). They have to answer *which cluster* explicitly, which is the same question the deploy answers — the explicit-target model (DEC-016) applied consistently rather than only where a deploy happens. A command that cannot name a destination fails closed rather than guessing.

**Rejected:** one resolution point with a scoped `KUBECONFIG`. Smaller, and it would scope credentials per process, which is a genuine benefit — but it makes the destination invisible at every call site (a reader of `sol_cli_rollback.ml` cannot see which cluster it touches), and nothing in the type system stops a new call site from being added outside the scoped path. If the credential-scoping benefit is wanted later, it can be added *underneath* required parameters; it is not an alternative to them.

### The surface this covers

**28 `Sol_cli_kubectl.*` call sites across 13 modules** — `cmd_up`, `cmd_status`, `cmd_deploy`, `cmd_logs`, `cmd_migrate`, `cmd_deploy_event`, `cmd_dev` in `bin/`, and `sol_cli_manifest`, `sol_cli_secret`, `sol_cli_rollback`, `sol_cli_rollout_diagnosis`, `sol_cli_deployment_state`, `sol_cli_up_execution` in `lib/` — plus helm's `--kube-context`.

## Scope

**1. Thread the destination** through the operation helpers, keeping the destination/scope boundary (FEAT-061): the Kubernetes seam learns *where*, never *what*.

**2. Remove the ambient reads.** Four files consult ambient context state today:

- `cli/sol/bin/cmd_up.ml` — `current_kube_context`, `is_known_local_dev_context`. `sol up` is the local deploy path, so it should pass the literal local destination; the guard becomes unnecessary because the context is named explicitly and `kubectl` fails if it is missing.
- `cli/sol/lib/sol_cli_port_forward.ml` — derives `--context` from the ambient context; it is a local-dev feature, so it should take the local destination.
- `cli/sol/lib/sol_cli_kubectl.ml` — `config_current_context` (and its test in `test_tool_adapters.ml`) should go.
- `cli/sol/bin/cmd_cloud_tf.ml` — reads `current-context` to name the context it just created, and runs `use-context` to restore the operator's. The temporary access for teardown should use a **scoped kubeconfig** rather than mutating the operator's kubeconfig at all.

`sol cloud init` may still **print** a context-switching command for the human's own `kubectl`. It must not make Sol depend on it.

**3. `sol cloud init` writes the destination into the target.** The abstraction-boundary criterion: a target Sol creates comes out with its destination already set, so an ordinary user never learns the field exists. If the target file is hand-written rather than generated, print the exact line to add instead of rewriting the user's file.

**4. The local carve-out, everywhere.** `k3d-sol-local` named literally for `sol up`, `sol dev up` and port-forwarding. Nothing else gets a default.

**5. Fail in a way that teaches.** When a target names no context, or the resolved context is unreachable, the error names the target, the context it expected, and what would otherwise have been used — so the change is obvious to someone whose habits were built on switching context first.

**6. Docs.** The tutorial's cloud section and the self-hosted substrate contract describe target-scoped destinations and no longer imply "switch context, then run `sol`". Examples show `sol cloud init` then `sol deploy` — never a hand-written context.

## Acceptance criteria

- A unit test proves resolution ignores the ambient context: with the machine's current context set to something unrelated, the destination for a target is unchanged.
- The resolved context reaches the executed command (assert on the argv the helpers build).
- No Kubernetes operation in the CLI decides its destination from `current-context`, and none mutates it — including `sol cloud init`'s own access to a cluster it is tearing down.
- A cluster-touching command with no resolvable destination fails closed, naming the target and the field.
- Local (`sol up`, `sol dev up`, port-forward) keeps working without ambient state, using the literal local destination.
- A target created by `sol cloud init` comes out with `kube_context` already set.
- Docs updated as above.

## Notes

FEAT-059 shipped the type, the field, the resolution and the lint. This is the binding half. See INFRA-011/012 for the ticket-tooling bugs found while splitting this work — neither blocks it.
