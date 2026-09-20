# FND-0014 — The deploy identity cannot maintain the release record, and the deploy reports success anyway

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **Severity:** escalated 2026-09-20 — originally recorded as a skipped prune (a
  warning); the second manifestation below is **fail-open** and silently leaves the
  release pointer stale
- **First identified:** 2026-09-20, AWS Run 8 step 6 (live)
- **Derived ticket:** `INFRA-051`
- **Invariant:** `INV-AUTH-6` (an identity Sol provisions may do everything Sol does
  as it) — the same shape as FND-0011, and the same underlying mechanism
- **Evidence class:** `BEHAVIORAL` (live) + `STATIC` (the Role's verbs, the store,
  the caller's error handling)

## Manifestation 1 — pruning cannot list

Every successful deploy ends with:

```text
warning: could not prune old releases: kubectl get configmap failed:
Error from server (Forbidden): configmaps is forbidden: User
"arn:aws:sts::<account>:assumed-role/sol-qual5-deploy/EKSGetTokenAuth"
cannot list resource "configmaps" in API group "" in the namespace "default"
```

Release records live in `default`, reached through a deliberately narrow exception
(`cli/platform/infra/base/platform_deploy_rbac.tf`, `sol_boundary_lease`):

| Rule | Verbs |
|---|---|
| `configmaps` in `default` | `create` |
| `configmaps` in `default` | `get`, `update`, `delete` |

Pruning is a *discovery* operation — it asks which records exist rather than
addressing one by name — so `kubectl get configmap` (a `list`) is refused. This one
at least reports itself.

## Manifestation 2 — the release pointer cannot be patched, and nothing says so

```text
Resource: "/v1, Resource=configmaps"  Name: "sol-release-current-pluto"  Namespace: "default"
error when patching "/tmp/sol-release-6576b5.json": configmaps "sol-release-current-pluto"
is forbidden: User "...sol-qual5-deploy..." cannot patch resource "configmaps"
in API group "" in the namespace "default"

Done. 1 service(s) deployed.
```

**Same mechanism as FND-0011, one object over.** `Sol_cli_release_store.record`
writes the per-release ConfigMap and then the *current pointer* through
`Sol_cli_kubectl.apply`. `kubectl apply` on an object that already exists degrades
to a **patch** — and `patch` is the one mutating verb the boundary-lease grant
withholds. So:

- the **first** pointer write succeeds (`create` is granted) — which is why a
  pointer exists at all;
- **every subsequent** write is refused — so the pointer still names an *older*
  release. Observed: it holds `r-6d35ecdb68a52996` while the deploy was recording
  `r-33d8e08d02d2a45c`.

The deploy then printed `Done. 1 service(s) deployed.` The operator is told the
release succeeded while the release identity was not advanced.

## What the release-record contract actually says

Established from the code, because the decision below depends on it:

- **What the pointer is for.** `Sol_cli_release_store.current` reads it; `sol
  rollback` restores from it (`cmd_rollback.ml:91` supplies `move_pointer`), and
  retention anchors on it (`Sol_cli_release_retention.prune ~current`). DEC-018
  makes the release identity what a rollback restores, so the pointer is the
  "which release is live" fact.
- **Whether advancing it is required for a successful deploy.** Per
  `cmd_deploy.ml:487-490`, **no — by design**:

  ```ocaml
  match Sol_cli_release_store.record_plan ~ctx:cluster ~apply_mode:… plan with
  | Error msg -> Printf.eprintf "warning: could not record release: %s\n%!" msg
  | Ok () -> (… prune …)
  ```

  Recording is best-effort, and the contract says so at the call site. That is a
  deliberate choice, not an oversight — which is exactly why the *consequence* is
  worth stating plainly: a best-effort record whose writes silently fail leaves
  rollback and retention pointing at a release that is no longer live, with a
  successful deploy reported on top.

### One discrepancy to settle, recorded rather than explained

The static contract says a record failure prints
`warning: could not record release: …`. **The observed run printed no such
warning** — only kubectl's own error, then `Done.`. `Sol_cli_process.run_ok` does
fail on a non-zero exit (`sol_cli_process.ml:231-235`), so the warning *should*
have followed. Either the failing apply was not reached through
`record_release_and_prune`, or its output was captured where the console does not
show it.

I am not asserting a mechanism I have not demonstrated. Determining it needs a
controlled reproduction — one deploy against a target whose pointer already exists,
with stdout and stderr captured separately — and that belongs to the ticket, not to
Run 8.

## The two problems, kept separate

1. **Missing authorization.** The grant has no `patch` on `configmaps` in
   `default`, while Sol *applies* the record. Fixing this is either a one-verb
   change to the boundary the RBAC file argues hardest for, or a change of
   mechanism — write the pointer in a way that does not need `patch`, such as an
   explicit `update` of an object it has just read (the same reasoning that fixed
   FND-0011 on the client side rather than widening the grant).
2. **The CLI's success/failure semantics when release recording fails.** Even with
   the authorization fixed, "the release identity was not advanced" is currently
   not an error, and — per the discrepancy above — may not even be a visible
   warning. Whether a deploy that could not record its release should succeed is a
   product decision about what the profile guarantees, and it is independent of the
   RBAC question. `sol rollback` depending on a pointer that silently did not move
   is the failure a user would actually experience.

## Suggested severity framing

The prune skip is cosmetic. The pointer is not: it degrades the recovery path the
profile is qualified on (rollback to a known release), and it does so while
reporting success. If the two are fixed together, the second should drive the
urgency.

## Not decided here

Both fixes are contract decisions — verb breadth versus mechanism, and fail-open
versus fail-closed — so the ticket's first task is to settle them, with a `DEC` if
they change what the profile guarantees. Deliberately not fixed during Run 8.

## Sources

- Live: Run 8, `deploy-20260920T201903Z-532619` (prune) and
  `deploy-20260920T213441Z-547990` (pointer), revision `d8d8c876`, target
  `qual/aws/us-east-1`; observed pointer value `r-6d35ecdb68a52996` while
  recording `r-33d8e08d02d2a45c`.
- `cli/platform/infra/base/platform_deploy_rbac.tf:123-159`
- `cli/sol/lib/sol_cli_release_store.ml:22-47,167-169`
- `cli/sol/bin/cmd_deploy.ml:484-507`
- `cli/sol/lib/sol_cli_kubectl.ml:20` and `cli/sol/lib/sol_cli_process.ml:231-235`
- `cli/sol/bin/cmd_rollback.ml:91`
- `internal/pipeline/audits/findings/FND-0011-deploy-namespace-reconcile-rbac-mismatch.md`
