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
