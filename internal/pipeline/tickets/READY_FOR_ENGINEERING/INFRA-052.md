---
id: INFRA-052
type: bug
severity: medium
title: The account-artifact guard does not catch a bare account id in prose
source: audit finding FND-0015 — the guard fired on a real Run 8 incident and the same episode exposed the gap
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0015-guard-misses-bare-account-id-in-prose.md`

## The defect

`internal/ci/check_no_account_artifacts.sh` states its rule as "a real-looking
12-digit AWS account id in any tracked text file is an error", but it only matches
account-*shaped* contexts:

```sh
'(arn:aws:[a-zA-Z0-9-]*:[a-zA-Z0-9-]*:[0-9]{12}:|[0-9]{12}\.dkr\.ecr|[Aa]ccount[^0-9]{0,12}[0-9]{12})'
```

A bare id in prose passes. One tracked file already carries one that way, twice:

```text
internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md:538,631
  … `production-single-region/v1`, <id> / us-east-1).
  … (same target path, <id> / us-east-1),
```

The omission is deliberate — the guard's comment says a bare `[0-9]{12}` pattern
"would false-positive on GitHub run ids" — so this is a considered trade that is
now wrong: the asymmetry is that a false positive costs a minute, while a false
negative is a permanent leak in a public repository, which is what HARDEN-002 run
2 actually cost.

## Acceptance criteria

1. A bare, non-placeholder 12-digit account id in tracked qualification material
   fails the guard, without a false positive on a GitHub run id, a hash prefix or a
   timestamp fragment. Prose adjacency to `account`, `aws`, a region token or an
   ARN fragment is the shape to target.
2. The two known lines in `HARDEN-002.md` are redacted to a placeholder, and the
   guard fails before and passes after — demonstrated, not asserted.
3. The guard keeps its current behaviour for the rules that already work: a
   tracked `sol/qual/` or `sol/qual2/` path, and an account id in an ARN,
   registry host or `account <id>` phrasing.
4. `internal/pipeline/audits/README.md`'s working rules name `git add -A`
   explicitly, alongside the existing worktree rule. The Run 8 incident was an
   agent reproducing HARDEN-002 run 2 with `git add -A` while a qualification
   target sat untracked in the tree; the guard caught it, and the working rules
   should make the next agent's mistake harder.

## Out of scope

The product defects Run 8 found (`INFRA-048`, `INFRA-050`, `INFRA-051`). This is
guard/process hardening, deliberately kept separate.
