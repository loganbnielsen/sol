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

## Completion notes (2026-09-25)

**Problem.** `Sol_cli_config.target_key_of_string` mapped six legacy flat target keys to a provider
by *string*: `Target_provider_owned (s, "aws")` / `(s, "gcp")`. Provider identity in a generic
module, in the one representation the provider-dispatch guard cannot see, since it counts
constructors.

**The two options, and what was chosen.** The ticket preferred moving the map behind the provider
boundary, with extending the guard as the fallback. The boundary named in the plan
(`Sol_cli_provider_capabilities`) is *above* `Sol_cli_config` — capabilities take a
`Sol_cli_config.target` — so asking it at parse time is a dependency cycle, and threading a
capability list through every `load` call site would have pushed provider knowledge into more
places, not fewer. So the map moved to where the dependency direction allows it and where provider
identity is approved to live: **`Sol_cli_provider`**, the provider tier that config already depends
on.

**Change.**
- `Sol_cli_provider.owned_legacy_keys : (string * t) list` (with `owned_legacy_key`) holds the six
  entries as *constructors*.
- `Sol_cli_config.target_key_of_string` asks `Sol_cli_provider.owned_legacy_key`, and
  `Target_provider_owned` now carries a `Sol_cli_provider.t` instead of a spelling, so the diagnostic
  names the block from the provider value.
- **And the guard now sees that representation**, since "gone today" is not "cannot come back":
  `check_provider_dispatch.sh` gained a zero-tolerance rule over the generic modules (everything
  except `sol_cli_provider*` and the `sol_cli_{aws,gcp}_*` implementations) for a provider name
  spelled as a string literal — `"aws"`, `"gcp"`, `"azure"`.

**Executable evidence.**
- `check_provider_dispatch.sh` passes on the real repository and still reports 1 dispatch / 0
  wildcards. The new rule is proven by three controls in `test_provider_dispatch_check.sh` (a
  generic module spelling `"aws"` *and* `"azure"` is rejected; the same spelling inside a
  provider implementation is accepted; a third provider present only in the provider list is
  admitted without editing the guard) and by a mutation control on the real repository: appending
  `let legacy_provider_name = "aws"` to `Sol_cli_cloud_lifecycle` makes the guard fail.
- **That mutation control found a bug in this guard, which is worth recording.** The first version
  tested membership with `case " $(printf '%s' $generic_files) "`; an unquoted `printf '%s'` with
  several arguments joins them *without separators*, so the pattern matched nothing and the rule
  silently checked nothing. The real-repository mutation caught it (the rule reported the boundary
  clean while a literal was present); single-file self-test fixtures could not, because with one
  file the joined string is still correct. Membership is now a loop, and the self-test gained a
  *two*-generic-file case that fails against the joined-string version — verified by reinstating
  the old version and watching the self-test reject it.
- The provider list the guard excludes and the names it looks for are both *derived* from
  `Sol_cli_provider.ml` (`to_string`, the HARDEN-005 technique), plus the deliberately-absent
  `azure`: adding a provider does not require editing this guard.
- **A second guard pinned the moved knowledge, and CI caught it.** `check_gcloud_interface.sh` asserted
  the old assignment site by exact text (`"provisioner_impersonator" -> Target_provider_owned (s,
  "gcp")` in `sol_cli_config.ml`). It now asserts the provider-owned assignment
  (`"provisioner_impersonator", Gcp` in `Sol_cli_provider.owned_legacy_keys`) and is mutation-checked
  in the same way: changing it to `Aws` makes the guard fail. The local sweep before pushing now runs
  *every* guard the CI workflow runs (31), not a hand-picked subset — the hand-picked subset is why
  this reached CI at all.
- The legacy-key diagnostic is unchanged from the operator's side: `cli/sol/test/test_config.ml`'s
  "belongs to the `aws.provisioner_role_arn`" expectation still passes, because the provider value is
  rendered with `to_string`.
- `dune build` and `dune test cli/sol/test/` pass.

**Canonical merge SHA.** The squash commit that moved this ticket to `DONE/`; recover it with
`git log --oneline -1 -- internal/pipeline/tickets/DONE/AUDIT-POST-003.md`.

- Demo/example: not applicable (cloud lifecycle internals); the diagnostic is unchanged.
- Language parity (DEC-022): no application-facing impact.
- Update `internal/planning/WORK_SUMMARY.md`.
