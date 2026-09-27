# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: INFRA-091 — one idea of Terraform's output contract (2026-09-26)

- Attempt 13 stopped minutes after INFRA-090 merged, at `error: the cloud root published no project_id`: the new check's parser accepted a bare string or a single-field `{"value": …}` object, while Terraform publishes `{"sensitive": …, "type": …, "value": …}`.
- The fix is reuse, not another parser: `Sol_cli_cluster.outputs_reader` already unwraps `value`, tolerates absent optional outputs and fails closed on absent or non-string required ones — it is what Attempts 11 and 12 went through to reach `Ready`.
- The regression fixture is a real payload: the eight outputs Attempt 13's captured state recorded, rendered by terraform 1.9.8. The lifecycle harness renders *that fixture* rather than declaring a shape of its own, and the quota scenario proves it crosses the parser before it may assert the refusal.
- `check_terraform_output_fixture.sh` + six mutations tie fixture, harness and parser to the one payload. Two vacuous-check traps were found and fixed while building it: a `pipefail` + `grep -q` pipeline that could never fire, and mutations whose anchors a formatter or a comment had already satisfied.
- `verify_bundle` is phase-aware: it requires the evidence of the roots the run actually entered, derived from Sol's echoed invocations. Attempt 13's pre-platform stop is a complete bundle; a run that reaches the platform still requires its state.
- FND-0063 is `FIXED_UNQUALIFIED`. The next GCP attempt is the discriminator — and would be the first to test `Ready` and Ready-state destruction.
