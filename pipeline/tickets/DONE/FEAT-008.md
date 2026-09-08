---
id: FEAT-008
type: feature
severity: medium
source: PRODUCT_ARCHITECTURE.md
branch: FEAT-008/deployment-plan-inspect-export
worktree: ../sun-FEAT-008-deployment-plan-inspect-export
---

Add deployment plan inspection and serialization.

**Depends on:** FEAT-005.

**Problem:** A deployment plan is useful as an internal model, but hosted deployment and CI workflows need a stable artifact that can be inspected, diffed, logged, and eventually submitted to a hosted control plane.

**Goal:** Make deployment plans serializable and inspectable without changing deploy behavior.

**Remediation:**

1. Add JSON serialization for deployment plans.
2. Add a human-readable plan summary printer.
3. Add a CLI option to print or write the plan before execution, such as `sun deploy --plan` or `sun deploy --emit-plan-to FILE`.
4. Include enough data for debugging:
   - workspace
   - environment name/mode
   - service specs
   - image refs
   - config keys
   - secret keys or refs, without secret values
5. Add tests for deterministic plan serialization.

**Out of scope:**

- Submitting plans to Sun hosted.
- Storing release history.
- Showing secret values.
- Backward compatibility promises for the first experimental plan JSON shape unless explicitly documented.

**Acceptance criteria:**

- The same workspace/environment/image tag produces byte-stable plan JSON.
- Plan output does not leak secret values.
- Existing deploy commands still behave the same unless the new inspection flag is passed.

**Decisions:**

- Mark serialized plan format as experimental until the hosted executor exists. Do not freeze the schema prematurely.
- Use `yojson` for serialization. It is already a project dependency; no new dep needed.

## Review — automated checks passed
All acceptance criteria met. to_json produces deterministic byte-stable JSON for identical inputs. Secret values are structurally absent from the output (only keys are serialised via secret_keys array). Config key-value pairs are fully included. Mode variant strings match spec (local/customer_cloud/sun_hosted). --emit-plan-to flag wires in cleanly before the executor loop; passing '-' prints to stdout. pp_summary prints a human-readable table. yojson added to lib and bin dune files. 6 new test cases cover valid JSON round-trip, determinism, secret value absence, secret key presence, config value presence, and mode string correctness. All 14 deployment_plan tests pass; full pre-commit suite (unit, observability, storage, kafka, e2e) green.
