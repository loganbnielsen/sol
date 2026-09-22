---
id: INFRA-050
type: bug
severity: high
title: A direct deploy must infer its secret backend from the destination, not default to a placeholder
source: audit finding FND-0013 — live AWS Run 8 step 6
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0013-direct-deploy-emits-empty-runtime-secret.md`

## The defect

`--secret-backend` carries a hard default of `kubernetes-placeholder`
(`cli/sol/bin/cmd_deploy.ml:880-890`), which always supplies a value and so
defeats the destination's own decision:

```ocaml
(* cli/sol/lib/sol_cli_env_target.ml *)
| Local _           -> Kubernetes_live
| Customer_direct _ -> Kubernetes_live
| Customer_gitops _ -> Kubernetes_placeholder
| Sol_hosted _      -> Kubernetes_placeholder
```

A target with no explicit destination classifies as `Customer_direct`
(`:33`), so a direct deploy emits a **redacted, empty** per-service Secret. The
workload `envFrom`s it and cannot start:

```text
Fatal error: exception Failure("sol-svc: config error: API key auth configured
but SOL_API_KEY/SOL_API_KEY_FILE is not set")
```

Observed live: `checkout-svc-secrets` had both keys with **empty values** while
the workspace's `sol-secrets` was correctly populated. The documented deploy
command — `sol deploy <target> --image-ref <svc>=<repo>@sha256:<digest>`, per
HARDEN-002 step 6 — has no `--secret-backend`, and `kubernetes-live` is
documented nowhere in `docs/`. Following the procedure as written deploys a
workload that cannot run.

## The fix

**Absence of the flag means "use the destination's default"**, not "use this
backend". One source of truth, so this class of bug cannot return:

1. an explicitly supplied `--secret-backend` overrides the inferred backend;
2. with no explicit override, `default_secret_backend` for the resolved
   destination applies;
3. direct/local therefore resolves to `kubernetes-live`;
4. GitOps/emit paths keep the placeholder behaviour they have now.

Do **not** simply change the hard-coded default from `kubernetes-placeholder` to
`kubernetes-live`: that leaves two competing defaults and fixes only the
symptom. Remove the competing default.

Update the flag's help: it currently says the option is "for GitOps output" and
"only meaningful with `--emit-to`", which contradicts the direct-deploy
inference and is how the operator was left without a working documented command.

## Acceptance criteria

1. A direct deploy with **no** `--secret-backend` writes real values into the
   per-service Secret.
2. GitOps/`--emit-to` still writes a placeholder (or an ExternalSecret for
   `external-secrets`), unchanged.
3. An explicit `--secret-backend` still overrides the inferred backend in both
   directions.
4. The CLI guard that rejects `kubernetes-live` with `--emit-to` still holds.
5. The three cases above have regression coverage, and the flag help describes an
   override rather than a GitOps-only option.
6. Live: re-running the documented step 6 command (no flag) against the existing
   target reconciles the already-present empty Secret with the real values and the
   workload starts.

## Out of scope

The `configmaps` prune warning recorded separately as `FND-0014`/`INFRA-051` —
the deploy identity cannot list ConfigMaps in `default`, so release pruning is
skipped with a warning. Same INV-AUTH-6 shape, different defect, and it is not
blocking.

## Completion — verified close-out (2026-09-22)

**The work landed in #390 (`d8d8c876`) and the ticket was never moved to DONE**, so
it kept reporting as actionable. Closed here after checking each criterion against
the code rather than assuming the comment meant it was done:

1–3. The competing default is gone: the flag is now
`opt (some string) None` — *no* default — and
`Sol_cli_env_target.resolve_secret_backend ?explicit` (`sol_cli_env_target.ml:87`)
returns the explicit choice when given and `default_secret_backend` otherwise, so a
direct/local deploy resolves to `kubernetes-live` and a GitOps target to
`kubernetes-placeholder` with nothing supplied.
4. The GitOps guard is intact (`cmd_deploy.ml:203-219`), and its comment now records
*why* it can only fire on an explicit flag: an absent flag resolves to the GitOps
destination's own placeholder rather than to a live backend.
5. `cli/sol/test/test_env_target.ml` has a `resolve_secret_backend (INFRA-050)`
section covering both directions, and the help text now reads "Omitted — the usual
case — the destination decides", with `kubernetes-placeholder` described as the
way to force a redacted Secret.
6. **Live and outstanding.** Re-running the documented step 6 command against the
live target is a qualification-run step, not something this repository can verify
offline. `FND-0013` therefore stays `FIXED_UNQUALIFIED`, and the live half is the
next run's to close — recorded here so closing this ticket does not read as
"verified against a real cluster".
