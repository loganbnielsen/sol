---
id: FEAT-063
type: feature
severity: medium
source: FEAT-059 review 2026-09-11 — the destination field landed; nothing consumes it yet
---

**Depends on:** FEAT-059.

**Related:** FEAT-068 (the `sol cloud` lifecycle half — `cloud init` writing the destination, teardown via a scoped kubeconfig — split out 2026-09-13 so this binding change lands on its own), DEC-016, DEC-020, FEAT-061 (the destination/scope boundary), REFAC-088 (the capability core this unblocks).

Bind every Kubernetes operation to the target's destination, so the cluster is chosen by the target rather than by whatever `kubectl` happens to be pointing at.

Until this lands, `kube_context` is expressible and checked but **not in force**: deploys still inherit the ambient context.

## Decided: destinations are required parameters

**Decision (2026-09-11): explicit threading, with a *required* parameter.** Not optional, and not the process-global alternative.

The asymmetry is what settles it: **a parameter can be relaxed from required to optional later, but never tightened from optional to required** — tightening breaks every caller. So the strict signature costs nothing now and preserves the option to loosen it if some caller genuinely cannot supply a destination. The reverse choice is permanent.

That also rejects the softer version of the same design: an optional `?destination` leaves unthreaded call sites silently inheriting the ambient context — the hidden input DEC-020 exists to remove, reproduced one layer down where it is harder to see.

**Accepted consequence: every cluster-touching command must resolve a destination**, including diagnostics (`sol logs`, `sol status`, `sol rollback`). They have to answer *which cluster* explicitly, which is the same question the deploy answers — the explicit-target model (DEC-016) applied consistently rather than only where a deploy happens. A command that cannot name a destination fails closed rather than guessing.

**Rejected:** one resolution point with a scoped `KUBECONFIG`. Smaller, and it would scope credentials per process, which is a genuine benefit — but it makes the destination invisible at every call site (a reader of `sol_cli_rollback.ml` cannot see which cluster it touches), and nothing in the type system stops a new call site from being added outside the scoped path. If the credential-scoping benefit is wanted later, it can be added *underneath* required parameters; it is not an alternative to them.

### The surface this covers

**28 `Sol_cli_kubectl.*` call sites across 13 modules** — `cmd_up`, `cmd_status`, `cmd_deploy`, `cmd_logs`, `cmd_migrate`, `cmd_deploy_event`, `cmd_local` in `bin/`, and `sol_cli_manifest`, `sol_cli_secret`, `sol_cli_rollback`, `sol_cli_rollout_diagnosis`, `sol_cli_deployment_state`, `sol_cli_up_execution`, `sol_cli_release_store` in `lib/` — plus helm's `--kube-context`.

**But the adapter is not the only way kubectl gets invoked**, which makes "thread the adapter and be done" wrong. Found while scoping the work (2026-09-11):

- `cli/sol/bin/cmd_logs.ml` builds a `kubectl get` inline and, for follow mode, **`Unix.execvp "kubectl"`** (line ~72). Because it `exec`s, no wrapper can inject a flag — the arguments must be built correctly *before* the exec, in that file.
- `cli/sol/lib/sol_cli_logs.ml` constructs its own kubectl argv.
- `cli/sol/bin/cmd_deploy_event.ml` and `cli/sol/bin/cmd_migrate.ml` build kubectl argv for exec/`run`.

So the criterion is not "the adapter takes a destination" but **"every kubectl invocation is scoped"**, and the check for it is a grep for `kubectl` across `cli/` that must return only the adapter plus the local-dev carve-out — with `cmd_cloud_tf.ml` as a known, recorded exception until **FEAT-068** converts its teardown to a scoped kubeconfig.

## Decided: the CLI grammar (2026-09-11)

**Local operations live under `sol local`; any operation against a configured target requires `--target <name>`; there is no current target and no implicit local fallback.** DEC-016's grammar section carries the reasoning and the two rejected alternatives (a `--local` flag, and a workspace current-target file).

What that means here:

- Cluster-touching commands gain a local counterpart — `sol local status`, `sol local logs`, `sol local rollback`, `sol local up` — and a **required `--target`** on the top-level form.
- A top-level cluster-touching command with no `--target` **fails closed**, and its error points at `sol local <command>`: the inference is not merely absent, the correct spelling is named so it is discoverable.
- `--local` must not exist, and both spellings must not be supported. One grammar, or the CLI starts accumulating aliases for one destination.
- The destination is therefore always visible in the invocation — the property DEC-020 asks for.

## Decided: cluster selection is destination state, not ambient state (2026-09-13)

The property this buys, stated plainly: **Sol can operate on several clusters independently — even concurrently — without switching, or depending on, the operator's active kubectl context.** `kubectl config use-context` makes the cluster a function of mutable user state; `kubectl --context <name>` makes it a function of the invocation. The failure this removes is not "wrong cluster" in the abstract but "correct command, wrong moment" — the `use-context` hazard.

Precisely, the destination is a **pair**: a kubeconfig source and a context name within it. Both are needed for a target to be fully determined, and today only one half is always explicit:

- The context name alone is resolved against whatever kubeconfig the process has loaded (the ambient `KUBECONFIG`, or `~/.kube/config` when unset). So `context = "prod"` with `kubeconfig = None` is *half* explicit — the name is chosen, the file it is read from is not. With a multi-file `KUBECONFIG` list, context names can also collide across files.
- A scoped `kubeconfig` **plus** the context name is the complete identity. That pair is what `sol cloud init` should produce (FEAT-068) — which is why FEAT-068 depends on this ticket rather than sitting beside it.

So the sharper failure to avoid is not "wrong context string" but **"right context string, resolved against the wrong kubeconfig."** Two consequences for this ticket:

- A context-only destination is a documented weaker mode, not an equivalent one. Where a kubeconfig is available it should be set.
- Errors and `sol target check` name the resolved destination — `Sol_cli_kube_destination.to_string` renders `context (kubeconfig …)` — so "what would you have used?" is answerable. This complements the existing note that a context cannot *prove* which physical cluster it names (FEAT-058): it may not even pin which file is consulted.

## Scope

**1. Restructure the CLI grammar, then thread the destination** through the operation helpers, keeping the destination/scope boundary (FEAT-061): the Kubernetes seam learns *where*, never *what*. The grammar comes first because it is what makes a destination *available* to diagnostics — before it, `sol status` has no way to name a cluster at all.

### Implementation note — thread one destination-side value, not a bare destination

The cost of this refactor is per **cross-cutting input**, and that cost is fixed by the call graph, not by the input itself: roughly sixteen files that reach kubectl need their signatures and forwarding changed either way. FEAT-061 then adds a *second* such input (scope) over the same call graph, and would repeat all of it.

So pass one small destination-side value through the helpers — a context record — rather than a bare `Sol_cli_kube_destination.t`, so the next input of the same kind rides the same channel instead of starting a new refactor.

Two boundaries on what may be in it, because a convenient record is exactly how boundaries like these fail:

- **Destination-side facts only**: how an operation reaches a cluster — context, kubeconfig, and any credential scoping. Nothing about *what* is being deployed.
- **Scope must not join it**, even though scope is also cross-cutting. The Kubernetes seam must never learn which services are being deployed (FEAT-061), so scope travels on its own channel even when the plumbing looks identical. Bundling the two would satisfy this ticket and break the next one.

**2. Remove the ambient reads.** Three files consult ambient context state today:

- `cli/sol/bin/cmd_up.ml` — `current_kube_context`, `is_known_local_dev_context`. `sol up` is the local deploy path, so it should pass the literal local destination; the guard becomes unnecessary because the context is named explicitly and `kubectl` fails if it is missing.
- `cli/sol/lib/sol_cli_port_forward.ml` — derives `--context` from the ambient context; it is a local-dev feature, so it should take the local destination.
- `cli/sol/lib/sol_cli_kubectl.ml` — `config_current_context` (and its test in `test_tool_adapters.ml`) should go.

(`cmd_cloud_tf.ml`'s `current-context`/`use-context` reads are **FEAT-068**, not here.)

**3. The local carve-out, everywhere.** `k3d-sol-local` named literally for `sol up`, `sol local up` and port-forwarding. Nothing else gets a default.

**4. Fail in a way that teaches.** When a target names no context, or the resolved context is unreachable, the error names the target, the context it expected, and what would otherwise have been used — so the change is obvious to someone whose habits were built on switching context first.

**5. Docs.** The tutorial's cloud section and the self-hosted substrate contract describe target-scoped destinations and no longer imply "switch context, then run `sol`". Examples show `sol cloud init` then `sol deploy` — never a hand-written context.

## Acceptance criteria

- A unit test proves resolution ignores the ambient context: with the machine's current context set to something unrelated, the destination for a target is unchanged.
- The resolved context reaches the executed command (assert on the argv the helpers build).
- No Kubernetes operation in the CLI decides its destination from `current-context` (the `cmd_cloud_tf` teardown is the recorded exception, deferred to FEAT-068).
- A cluster-touching command with no resolvable destination fails closed, naming the target and the field.
- Local (`sol up`, `sol local up`, port-forward) keeps working without ambient state, using the literal local destination.
- Docs updated as above.

## Notes

FEAT-059 shipped the type, the field, the resolution and the lint. This is the binding half; FEAT-068 is the `sol cloud` lifecycle half. See INFRA-011/012 for the ticket-tooling bugs found while splitting this work — neither blocks it.
