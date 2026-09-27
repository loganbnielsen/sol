---
id: INFRA-091
type: bug
severity: high
source: GCP qualification Attempt 13 (2026-09-26)
---

# INFRA-091 — read the project from Terraform's output wrapper

**Depends on:** None.

GCP qualification Attempt 13 stopped in the disk-quota check that landed minutes earlier:

```
error: the cloud root published no project_id
```

`Sol_cli_gcp_cluster.project_id_of_outputs_json` accepts a bare string or an object whose only field
is `value`. Terraform emits `{"sensitive": …, "type": …, "value": …}` (reproduced offline), so no
output matches and the check refuses before observing anything. The unit test and the offline
harness stub shared the parser's assumption, so all three agreed with each other and disagreed with
Terraform. See `FND-0063` and the run record
`internal/qualification/records/2026-09-26-gcp-attempt13-infra090-outputs-shape.md`.

## Status

**Implemented 2026-09-26.** Offline acceptance met; the live acceptance is the next GCP run, which
is what turns `FND-0063` from fixed into qualified.


Promoted on 2026-09-26 with the fix's shape established by the failure itself.

## Remediation

1. Parse `value` out of the output wrapper (the documented shape); the bare-string case is not a
   shape Terraform produces.
2. Use the *captured* payload from the run record as the unit-test fixture, and assert that a
   single-field `value` object no longer parses (so the old assumption cannot come back quietly).
3. Correct the offline lifecycle harness's `terraform` stub to emit wrapped outputs for every
   output it serves, and re-run the exhausted-quota scenario to prove it still refuses — a stub
   shape the product cannot parse would make the scenario vacuous.
4. Relax `verify_bundle` so a platform state that was never initialised does not mark the bundle
   INCOMPLETE when the run stopped before the platform (Attempt 13's bundle was flagged despite
   being complete for the phase it reached).

## Acceptance criteria

- The captured payload parses to the project; the old shape does not.
- The offline harness exercises the real wrapper and its quota scenario still refuses.
- A GCP run from the fixed revision proceeds past the quota check, printing the observation and
  Sol's declared 20 GiB minimum, and reaches the platform install.

## Completion notes (2026-09-26)

**The parser change.** `Sol_cli_gcp_cluster.project_id_of_outputs_json` no longer holds a private idea
of Terraform's output shape. It reads the project through `Sol_cli_cluster.outputs_reader`, the reader
Sol already uses for every other output and the one Qualification Attempts 11 and 12 went through to
reach `Ready`:

```ocaml
let project_id_of_outputs_json text : (string, string) result =
  match Sol_cli_cluster.outputs_reader ~provider:"GCP" text with
  | exception Yojson.Json_error message ->
    Error (Printf.sprintf "invalid outputs JSON: %s" message)
  | (_raw, string, _optional_string) -> string "project_id"
;;
```

That is the contract Sol actually consumes: `value` unwrapped from Terraform's record, absent
*optional* outputs tolerated as null, absent or non-string *required* ones refused with a named
error — and, because this module names the provider, the refusal an operator sees is a GCP one.
Unparseable JSON is refused too, which the shared reader raises on and the previous code did not
catch at all.

**The regression fixture.** `cli/test/fixtures/terraform-output-gcp-cloud.json` is a real
`terraform output -json` payload: the eight outputs Attempt 13's *captured state* recorded
(`artifact_registry`, `cluster_name`, `docker_auth_command`, `kube_context`, `kubeconfig_command`,
`project_id`, `provisioner_service_account`, `region`), rendered by terraform 1.9.8 from a root
declaring exactly those. Every entry carries Terraform's own `sensitive`/`type`/`value` fields,
which is what makes the fixture evidence about the external tool rather than about Sol.

`cli/test/test_gcp_outputs.ml` reads it and asserts: the payload parses to `sol-qualification`; every
entry carries those three fields; and malformed (`{}`, invalid and truncated JSON), absent, null,
non-string and blank payloads all refuse.

**The stub correction.** `internal/ci/test_cloud_lifecycle_offline.sh`'s fake `terraform` no longer
declares an outputs payload of its own: it renders the fixture (substituting the names its target
uses). The invented `{"project_id":{"value":…}}` shape is gone with it — that shape and Attempt 13's
parser agreed with each other, which is why a green scenario coexisted with a product that refused
every real run.

**Proof the quota scenario is no longer vacuous.** It now asserts the crossing itself: the run must
reach the provider's quota read (`compute regions describe` present in the argv log) and must *not*
stop at the parser, before it may assert the refusal's numbers. A companion scenario pins the other
direction: an output set without `project_id` refuses with
`GCP Terraform output "project_id" is missing or not a string` and never reaches the provider at all.

**Drift protection, without a second schema.** `internal/ci/check_terraform_output_fixture.sh` ties
the three consumers to the one payload: the fixture must still be Terraform's record shape, the
harness must render *it* (and must not carry the invented shape in code), and the product must read
through `Sol_cli_cluster.outputs_reader`. Six mutations prove it fires
(`no-type`, `project-is-not-a-string`, `no-project-id`, `sensitive-not-a-bool`,
`harness-declares-its-own-shape`, `harness-invents-the-old-shape`, `parser-reads-a-private-shape`).

Two traps of exactly this ticket's kind were found and fixed while building that guard, both worth
recording because each made a check silently vacuous: a `grep -v … | grep -q …` pipeline whose
upstream grep took SIGPIPE, so `pipefail` reported false forever; and two mutations whose anchors had
already been rewritten by `dune fmt` or satisfied by a *comment*, so they changed nothing and
"passed" by accepting an unmutated tree.

**Phase-aware bundle verification.** `verify_bundle` now requires the evidence of the phases the run
entered, derived from Sol's own echoed invocations in `cloud-apply.log`: the cloud root's state once
that root appears, the platform root's state once *it* appears, and no weaker for either once
reached. Attempt 13's supported pre-platform stop is therefore a complete bundle, which is what it
was. The manifest now states which roots were reached, so a reader is not left to re-derive it, and
two new scenarios in `test-live-qual.sh` cover both directions (a pre-platform stop is not incomplete;
a run that reached the platform still requires its state).

**Verification run:** `opam exec -- dune test framework/… cli/test/` → rc 0 (the exact CI command);
`test_gcp_outputs` 3 cases; the offline lifecycle harness rc 0; `test-live-qual.sh` 140 → **142
assertions, 0 failures**; the guard pair and its mutations green; `check_platform_storage_requirement`,
`check_provider_dispatch`, `check_gcloud_interface`, `check_cert_manager_readiness`,
`check_kubernetes_object_ownership`, `test_ticket_transitions` all green; `check_ocamlformat.sh --all`
green.

**Demo/example coverage:** not applicable — an internal parser for a Terraform tool's output on the
cloud install path, with no `sol.toml` field, CLI surface, framework primitive or generated manifest
for an app author to read.

**Language parity (DEC-022):** no application-facing impact; no primitive, contract, metric or retry
semantic is involved.

**Canonical merge SHA:** `git log --oneline -1 -- internal/pipeline/tickets/DONE/INFRA-091.md`.
