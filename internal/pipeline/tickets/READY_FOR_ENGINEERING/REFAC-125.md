---
id: REFAC-125
type: refactor
severity: medium
title: Typed tool errors instead of stderr substring matching -- ask the tool for a structured answer, and classify once per tool where it cannot give one
source: operator review (2026-09-26, sol-logan-comments), sol_cli_kubectl.ml resource_type_absent
---

**Depends on:** REFAC-124.

## The problem

The operator asked, on `Sol_cli_kubectl.resource_type_absent`: "do we need to have strings validating stuff like this or is there a cleaner API contract?" `git grep -n 'Sol_cli_string.contains' origin/main -- cli/lib` (2026-09-26) finds about 18 sites that decide control flow from a tool's message text:

- "NotFound" / "not found": `sol_cli_boundary_lease.ml`, `sol_cli_release_store.ml` (3), `sol_cli_secret.ml`, `sol_cli_substrate.ml`, `sol_cli_deployment_state.ml`, `sol_cli_rollout_diagnosis.ml`.
- "AlreadyExists": `sol_cli_boundary_lease.ml`, `sol_cli_manifest.ml`.
- Optimistic-concurrency conflicts: `sol_cli_boundary_lease.ml` (3 phrasings).
- A missing CRD: `sol_cli_kubectl.ml` (2 phrasings).
- AWS and GCP error texts: `sol_cli_aws_cluster.ml`, `sol_cli_gcp_destruction.ml`.

Each site knows kubectl's wording. A wording change, or a missed phrasing, turns "absent" into a hard error, or a real error into "absent". release_store's `NotFound` branch was already dead on main once (fixed in REFAC-116).

## Remediation

1. **Ask for a structured answer where the tool has one:**
   - `kubectl get … --ignore-not-found -o json`: empty stdout means absent, so the call returns `Ok None`.
   - `kubectl api-resources --api-group=<g> -o name` for "is this CRD installed".
   - `kubectl create` → `apply` (or server-side apply) where "already exists" just means "done".
   - `aws … --output json` error codes, and gcloud `--format=json`, where the CLI exposes a code.
2. **Where the tool can only say it in text** (for example kubectl optimistic-concurrency conflicts), one classifier per tool adapter maps `Non_zero` to a typed error, such as `Sol_cli_kubectl.error = Not_found | Already_exists | Conflict | Failed of Sol_cli_process.error`. The phrasings live there once, with a test holding the real messages. Call sites match variants, not strings.

## Acceptance criteria

- `git grep -n 'Sol_cli_string.contains' -- cli/lib` lists no tool-output classification outside the per-tool classifiers. The notes list what remains (e.g. `sensitive_vars`, `port_forward` process args, which aren't tool errors).
- Every classifier has a test with the verbatim message it recognises, plus a positive control that an unrelated failure stays `Failed`.
- Where a structured flag replaced a string match, the offline harness or a unit test shows the absent case as `Ok None`.
- Demo/example: not applicable (internal). Language parity: no impact.
