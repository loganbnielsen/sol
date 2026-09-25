---
id: AUDIT-POST-003
type: audit-finding
severity: low
source: internal/pipeline/audits/2026-09-25_cloud_lifecycle_post_audit.md
---

Provider identity written as string literals bypasses the dispatch ratchet

**Depends on:** None.

**Related:** REFAC-092, REFAC-098, SEC-010, AUDIT-POST-002

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S1.c, § S6, § S11.

## Problem

`Sol_cli_config.ml:283-288` maps six provider-native target keys to raw provider strings:

```ocaml
| "state_lock_table" | "provisioner_role_arn" | "cluster_access_role_arn"
| "deploy_role_arn" | "operator_role_arn" -> Target_provider_owned (s, "aws")
| "provisioner_impersonator" -> Target_provider_owned (s, "gcp")
```

`internal/ci/check_provider_dispatch.sh` counts only `Sol_cli_provider.Aws|Gcp` and
`Aws_outputs|Gcp_outputs` (`:48`), so provider identity expressed as a string is invisible to it.

**Reproduced (2026-09-25), with a positive control:** a throwaway tree whose only provider knowledge
is `Some ("aws", "aws")` / `Some ("gcp", "gcp")` makes the guard print
`0 provider-dispatch occurrence(s)` and exit 0; the same file rewritten with
`Sol_cli_provider.Aws`/`Gcp` constructors is rejected with `2 provider-dispatch occurrence(s)`.

## Root cause

REFAC-098 moved provider-native configuration out of the flat target record into the provider's own
block, and needed a good error for an operator who still writes the old flat key. That error was
implemented as a key→provider-name map inside the generic config parser, which is precisely the
"provider selection in a generic module" the ratchet exists to prevent — but expressed in a form the
ratchet cannot see.

## Impact

The program's claim that the provider boundary is executable-guarded is weaker than stated: an
entire class of provider knowledge in generic modules escapes the ratchet. The live instance is
bounded (six legacy key names; it does not grow when a provider is added), so there is no behavioural
defect — the defect is that the guard would not have noticed.

## Remediation

Prefer deleting the misplaced knowledge over teaching the grep provider semantics — but only if that
is genuinely smaller.

- **Option A (preferred if small):** move the legacy-key→provider map behind the provider boundary —
  e.g. each provider's capabilities/registry exposes the legacy key names it owns, and generic config
  asks whether a key is provider-owned and, if so, which provider's block should carry it. Keep the
  same operator-facing message.
- **Option B (acceptable if Option A is more machinery than six entries warrant):** extend
  `check_provider_dispatch.sh` to also count provider-name string literals (`"(aws|gcp)"`) in
  generic modules, allowlisting the current instance with a one-line reason and a shrinking ratchet.

Either way the invariant is: generic modules cannot silently accumulate provider selection or
identity outside the explicitly approved provider boundary.

## Acceptance criteria

- The known raw-string provider identity is either gone from generic config or explicitly covered by
  the architectural guard.
- A positive-control test proves the guard (or the new check) fails on the representation that
  previously escaped it; the existing mutation test still passes.
- The legitimate provider-dispatch count stays at or below its current baseline (1 dispatch, 0
  wildcards) and no wildcard provider dispatch is introduced.
- `soldev`/build/tests green; the operator-facing "declare it as `aws.state_lock_table`" message is
  preserved (or improved) for a target that still uses a flat key.

## Completion notes (required)

- Problem / root cause / change / executable evidence / canonical merge SHA.
- Say which option was chosen and why it was the smaller one.
- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
