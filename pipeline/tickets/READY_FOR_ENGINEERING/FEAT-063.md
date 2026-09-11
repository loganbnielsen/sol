---
id: FEAT-063
type: feature
severity: medium
source: FEAT-059 review 2026-09-11 — the destination field landed; nothing consumes it yet
---

**Depends on:** FEAT-059.

Bind every Kubernetes operation to the target's destination, so the cluster is chosen by the target rather than by whatever `kubectl` happens to be pointing at.

Until this lands, `kube_context` is expressible and checked but **not in force**: deploys still inherit the ambient context.

## Decide this first — the mechanism

Two candidates, materially different, and the choice determines the size of the change:

1. **Explicit threading.** Give the kubectl/helm helpers a destination parameter and thread it through their callers. Strongest reading of "explicit", and a reader of any call site can see where it goes. Measured surface: **28 `Sol_cli_kubectl.*` call sites across 13 modules** — `cmd_up`, `cmd_status`, `cmd_deploy`, `cmd_logs`, `cmd_migrate`, `cmd_deploy_event`, `cmd_dev` in `bin/`, and `sol_cli_manifest`, `sol_cli_secret`, `sol_cli_rollback`, `sol_cli_rollout_diagnosis`, `sol_cli_deployment_state`, `sol_cli_up_execution` in `lib/` — plus helm's `--kube-context`.
   - If the parameter is **optional**, unthreaded call sites silently keep inheriting the ambient context. That is precisely the failure mode this session kept finding: something that looks fixed while a path still isn't. Do not do that.
   - If it is **required**, the compiler enumerates every site, and every cluster-touching command must resolve a destination. That is the honest version, and it implies the explicit-target model is applied to diagnostics too (`sol logs`, `sol status`): they need to know *which* cluster, which is the same question the deploy asks.
2. **One resolution point, scoped child environment.** Resolve the destination once at the start of a cluster-touching command and give every child process a scoped `KUBECONFIG`. Far smaller, deterministic, and it also keeps other environments' credentials out of the process — a security win in its own right, and the thing the hosted platform needs anyway. Cost: implicit at the call sites; a reader of `sol_cli_rollback.ml` cannot see which cluster it touches.

**Recommendation: (1) with a required parameter.** "Explicit" is the whole point of DEC-020, and an optional parameter reintroduces the hidden input one layer down. If that is judged too large, (2) is defensible — but say so in the ticket, because the difference is architectural, not cosmetic.

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
