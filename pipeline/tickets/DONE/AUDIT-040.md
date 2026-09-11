---
id: AUDIT-040
type: audit-finding
severity: medium
source: project/audits/2026-06-12j_audit.md
branch: AUDIT-040/cronjob-pod-labels
worktree: /home/lbendtly/Code/sun-AUDIT-040-cronjob-pod-labels
---

`cronjob_doc` pod template missing `app: <name>` label — NetworkPolicy never matches `-fn` workload pods

**Depends on:** None.

**Description:** `cronjob_doc` renders the `spec.jobTemplate.spec.template` without a `metadata.labels` section. Pods spawned by the CronJob therefore carry no labels. `network_policy_doc` (always included in `common` for all primitives including `Fn`) uses `podSelector: matchLabels: app: <name>`. Since no CronJob pod carries this label, the generated NetworkPolicy matches no pods and applies no traffic restrictions to the `-fn` workload. By contrast, `deployment_doc` and `rollout_doc` both set `app: <name>` in their pod template labels, so their NetworkPolicies work correctly.

**Impact:** A `-fn` workload that is expected to have network egress restricted to DNS + Redpanda + PostgreSQL + monitoring is in fact unrestricted. Exfiltration or unexpected outbound connections from a compromised function pod are not blocked by the generated policy. The manifest passes `kubectl apply` without error; the misconfiguration is invisible to the operator.

**Remediation:** In `cli/sun/lib/sun_cli_manifest.ml`, add a `metadata: labels: app: %s` block to the pod template inside `cronjob_doc`. Insert before the `spec:` line of the job pod template (around line 535 in the format string):

```yaml
          metadata:
            labels:
              app: %s
```

Add `name` as the positional argument for this new `%s`. Add a test in `cli/sun/test/test_manifest_render.ml` that asserts the rendered CronJob YAML contains `app: <service-name>` in the pod template labels section, matching the pattern checked for Deployment workloads.

## Review — automated checks passed
Build clean, all tests pass. Diff touches only cli/sun/lib/sun_cli_manifest.ml and cli/sun/test/test_manifest_render.ml — project/tickets/ untouched. The metadata/labels block is inserted at the correct nesting level (jobTemplate.spec.template.metadata.labels) with app: %s and the extra name positional arg placed correctly as the 4th argument in the format string. The fix mirrors the pattern used in deployment_doc and rollout_doc. The new test in the fn suite uses extract_kind_block to scope the assertion to the CronJob and checks for app: invoice-fn. No wrapped true libraries introduced.
