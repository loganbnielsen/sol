---
id: FND-0063
type: audit-finding
severity: high
source: GCP qualification Attempt 13 (2026-09-26), revision d44c85d6
---

# The GCP disk-quota check cannot read the project from Terraform's outputs

**State:** `FIXED_UNQUALIFIED` — fixed 2026-09-26 in `INFRA-091`. `project_id_of_outputs_json` now
reads the project through `Sol_cli_cluster.outputs_reader`, the reader Sol already uses for every
output (and the one Attempts 11 and 12 went through to reach `Ready`), with the captured payload as
the regression fixture, the lifecycle harness rendering that same payload, and a guard plus six
mutations holding the three consumers to it. **Not qualified:** no live run has yet crossed the
fixed parser; the next GCP attempt is the discriminator.

**Depends on:** None.

Found live by qualification Attempt 13, minutes after `INFRA-090` merged: the run stopped at the new
disk-quota check with `error: the cloud root published no project_id`.

## Problem

`Sol_cli_gcp_cluster.project_id_of_outputs_json` parses the cloud root's `terraform output -json`
payload and accepts only a bare string or an object with a single `value` field. Terraform wraps
every output in `{"sensitive": …, "type": …, "value": …}`, so no output ever matches: the project is
always reported missing and the check refuses before it can observe anything.

Reproduced offline (`/tmp/tfshape`, a root with one string output and no providers):

```json
{ "project_id": { "sensitive": false, "type": "string", "value": "sol-qualification" } }
```

## Root cause

The parser encoded an assumption about Terraform's output format that was never checked against
Terraform. The unit test and the offline harness stub both used the same bare shape, so all three
agreed with each other and disagreed with the provider tool. Fail-closed behaviour limited the
damage: the run refused instead of proceeding against an unknown project, and the target was
destroyed by the supported path leaving no residue.

## Impact

Every GCP lifecycle run from `d44c85d6` stops immediately after the substrate is created — about
8 minutes and a short-lived billable cluster per attempt — and no platform work can proceed. The
same parser is on the path of the invariant `INFRA-090` exists to enforce, so the check cannot be
qualified until it is fixed.

## Remediation

Read `value` from inside the wrapper rather than requiring it to be the only field, and stop
accepting a bare string (Terraform never emits one, and accepting it is what let the wrong
assumption look covered):

1. `project_id_of_outputs_json` accepts `{"project_id": {"value": "<string>"}}` plus the bare-string
   form only if it is genuinely possible to observe — the wrapper is the documented shape.
2. The test fixture is the **captured** payload above, taken from Terraform's own output, not a
   hand-written approximation of it.
3. The offline lifecycle harness's `terraform` stub emits the real wrapper for every output it
   serves, so the whole lifecycle is exercised against the shape Terraform produces. Any other stub
   output shape is a second, silent version of this defect.

Narrowest justified classification: a defect in Sol's own parsing of a provider tool's output — not
a provider defect, not a qualification-harness defect.

## Acceptance criteria

- The parser reads the captured payload and returns the project.
- The test fails against the captured payload if the parser reverts to requiring a single field.
- The offline lifecycle harness's `terraform` stub emits wrapped outputs, and the disk-quota
  scenario still refuses when the quota is exhausted (the scenario must not become vacuous by
  reading a stub shape the product cannot parse).
- A GCP run from the fixed revision reaches the platform install; the quota line prints the
  observation and Sol's declared minimum.
