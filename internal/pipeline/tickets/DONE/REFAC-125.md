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

## Completion notes

**Premise verified (2026-09-26):** `git grep -n 'Sol_cli_string.contains' -- cli/lib cli/bin` listed 19 kubectl/AWS classifications by message text across 9 files.

- **One classifier, and it is a view.** `Sol_cli_kubectl.classify : Sol_cli_process.error -> reason` gives `Not_found | Already_exists | Conflict | No_resource_type | Refused | Other`. It reads kubectl's status reason, the `(<Reason>)` in "Error from server (<Reason>): …", and names the two client-side messages that have none (a missing resource type; an unauthenticated client). It is the one place kubectl's wording is known.
- **Messages come from the original error, in kubectl's own words.** No function invents prose for a classified error (operator review: substituting our own message is destructive). A first draft had a `failure_to_string` that turned "secrets is forbidden: User X cannot get …" into a generic phrase, and the existing release-store test ("carries kubectl's reason") caught it; it is gone.
- **`Sol_cli_process.error_to_string` falls back to stdout** when a non-zero exit wrote nothing to stderr, instead of dropping it.
- **`get_if_present`** returns `Ok None` when kubectl answers NotFound, and `Error` for every other failure. Absence is read from the same status reason. `--ignore-not-found` was considered and not used: it exists only for get and delete, and NotFound must also be read on create (a missing namespace), so one mechanism serves every verb.
- **Call sites now match reasons:**
  - lease acquire (`Already_exists`) and replace (`Conflict`), which were three phrasings before;
  - the lease, release pointer, release record, live ConfigMap, Secret and consumer-group reads (`get_if_present`);
  - `sol status`'s namespace presence;
  - the diagnosis CronJob read;
  - `create_idempotent` (`Already_exists`), which now returns kubectl's error rather than a string;
  - the substrate's operator bindings (`Not_found`);
  - rollouts/secret listing (`No_resource_type`);
  - the AWS de-escalation probe (`Refused`), replacing its own word list.
- **The lease RBAC guard** (`check_production_infra.sh`) now maps the lease's calls to the verbs they issue (`get_if_present` is a get; `classify` issues nothing). Positive control: adding `Sol_cli_kubectl.patch` to the lease fails it with "…create delete get patch replace".
- **Tests:**
  - the classifier against kubectl's verbatim messages for every reason;
  - negative controls: an unreachable server, a timeout, and a reason word inside prose are all `Other`;
  - the message keeps kubectl's words;
  - `error_to_string` keeps stdout.
- **What remains of `Sol_cli_string.contains` in `cli/lib`+`cli/bin`:**
  - the classifier itself;
  - `sol_cli_sensitive_vars.ml` (reading Terraform source, not tool errors);
  - `sol_cli_gcp_destruction.ml`, documented as deliberate: gcloud publishes no structured result, and Attempt 4 depended on its wording list;
  - `sol_cli_port_forward.ml`, process arguments rather than an error, which is REFAC-126.
- **Verification:** 66 CLI suites pass; format is clean; the offline lifecycle harness passes, including its "You must be logged in (Unauthorized)" fixture, which is now read as `Refused`.
- **Demo/example:** not applicable (internal). **Language parity:** no impact.
