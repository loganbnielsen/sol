---
id: CODEX_STYLE_AUDIT-103
type: bug
severity: medium
title: "Validate secret emission options without silently substituting a different backend"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Validate secret emission options without silently substituting a different backend

**Depends on:** None.

**Principles:** 2, 7, 14, 20–23, 27, 31–33, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/bin/cmd_deploy.ml:931`: secret_backend_term replaces requested external-secrets with kubernetes-placeholder when emit-to is absent, after printing a warning.
- The same constructor accepts any secret-store-kind string and defaults unchecked refresh interval text into the emission record.
- `cli/lib/workspace/sol_cli_manifest.ml:7` and manifest_yaml.ml:180 carry store_kind as raw text into YAML.
- Backend help still says direct deploy writes real values, whereas `sol_cli_deployment_render.ml:111` emits no Secret for Kubernetes_live after BUG-054.

## Mechanism and impact

Explicit operator intent is changed at argument parsing, so downstream backend guards do not see the requested mode. Dry-run can succeed with a different backend. Invalid finite-domain store kinds become malformed GitOps artifacts, and current help contradicts secret authority.

## Remediation

Normalize the emission options into a validated request before effects. Reject unsupported mode/flag combinations rather than changing them. Parse store kind into its supported variant and validate the actual supported interval syntax at the owning boundary. Make command help reflect operator-owned live Secrets and emission behavior; keep existing executor safety checks.

## Acceptance criteria

- Requested external-secrets without its supported emission mode refuses without producing placeholder artifacts.
- Unknown store kind, malformed interval, missing required store reference, and irrelevant dependent flags have explicit tested outcomes.
- Valid SecretStore/ClusterSecretStore requests render the intended objects.
- Live/direct help accurately describes consumed secret references and sol secret ownership.
- Argument failure happens before file output, provider setup, or application mutation.

- Demo/example: update runnable GitOps secret emission examples and direct secret setup instructions.
- Language parity: shared CLI emission behavior applies equally to both languages.

## Existing work and scope

BUG-054 completed live secret ownership. This ticket fixes stale command-edge semantics and validation, not a new secret-authority decision. No matching open owner was found.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
