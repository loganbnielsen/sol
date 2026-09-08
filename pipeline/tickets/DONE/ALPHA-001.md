---
id: ALPHA-001
type: verification
severity: high
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: ALPHA-001/release-user-dogfood
worktree: /home/lbendtly/Code/sun-ALPHA-001-release-user-dogfood
---

Run the post-hardening release-user dogfood.

**Depends on:** FEAT-020, FEAT-021, FEAT-022, FEAT-023.

**Problem:** Dogfood Alpha proved the source-checkout path and first release
binary. After GitOps secret backend refs, plan completeness, self-contained
release bundles, and `sun logs` Grafana pointers land, engineers need to verify
the product as a release user, not as a framework contributor.

**Goal:** Prove that the public alpha path works from a release artifact through
local deploy, operations, plan inspection, and GitOps export.

**Runbook:**

1. Install `sun` from the release bundle in a clean temp directory. Do not use a
   source checkout or `SUN_HOME`.
2. Verify:

   ```bash
   sun --version
   which sun
   ```

3. Create a new workspace:

   ```bash
   mkdir -p /tmp/sun-alpha-dogfood
   cd /tmp/sun-alpha-dogfood
   sun new workspace alpha_acme
   cd alpha_acme
   dune build
   ```

4. Run the local product loop:

   ```bash
   sun dev up
   sun up
   sun migrate --table alpha_acme_migrations
   sun status
   sun logs payments/charge_svc --no-follow --tail=50
   ```

5. Exercise the generated app:

   ```bash
   curl -sf http://localhost:8080/health
   curl -sf -X POST http://localhost:8080/charges \
     -H 'Content-Type: application/json' \
     -d '{"customer_id":"cus_alpha","amount_cents":777,"currency":"usd"}'
   curl -sf http://localhost:8080/notifications
   ```

6. Verify deployment review artifacts:

   ```bash
   sun deploy --dry-run --emit-plan-to /tmp/alpha-plan.json
   sun deploy --emit-to /tmp/alpha-gitops \
     --secret-backend external-secrets \
     --secret-store-ref alpha-store \
     --secret-remote-prefix /alpha/acme
   ```

7. Inspect outputs:

   ```bash
   grep -q '"topics":' /tmp/alpha-plan.json
   grep -q '"migrations":' /tmp/alpha-plan.json
   grep -R "kind: ExternalSecret" /tmp/alpha-gitops
   ! grep -R 'stringData:.*".\\+"' /tmp/alpha-gitops
   ```

8. Record findings in `project/dogfood/ALPHA_001_<YYYY-MM-DD>.md`.

**Acceptance criteria:**

- The release bundle works without cloning the Sun repo or setting `SUN_HOME`.
- The generated workspace builds.
- `sun dev up`, `sun up`, `sun migrate`, `sun status`, and `sun logs` all work
  from the generated workspace.
- `sun logs` prints a Grafana Explore URL for the selected service.
- The plan JSON includes non-empty topics and migrations for the generated app.
- GitOps output contains ExternalSecret resources and no secret values.
- Every failure, workaround, timing issue, and doc mismatch is recorded.

