# FND-0015 — The account-artifact guard misses a bare account id in prose

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-20, when the guard caught a real incident during Run 8
- **Derived ticket:** `INFRA-052`
- **Evidence class:** `STATIC` (the guard's patterns against a tracked file it does not flag)

## Origin: the guard worked

While landing Run 8's findings, `internal/ci/check_no_account_artifacts.sh` failed
the `test` job because a commit had swept the untracked qualification target in
with `git add -A` — the exact HARDEN-002 run 2 incident the guard was written for,
reproduced by an agent that had read the file's own comment. It caught both rules:
the account id in the target and the tracked `sol/qual/` path. The commit was
amended (target untracked again, account id redacted from the tracked documents).

That the guard fired is the good news, and it is recorded here so the incident is
not silently absorbed. What follows is the gap the same episode exposed.

## The gap

The guard's rules are "deliberately high-signal" — it matches account-shaped
patterns only:

```sh
'(arn:aws:[a-zA-Z0-9-]*:[a-zA-Z0-9-]*:[0-9]{12}:|[0-9]{12}\.dkr\.ecr|[Aa]ccount[^0-9]{0,12}[0-9]{12})'
```

A bare 12-digit account id in prose therefore passes. One tracked file already
carries one, in exactly that form:

```text
internal/qualification/records/2026-09-18-aws-run5-attempt1.md:9
  `production-single-region/v1`, <id> / us-east-1).
internal/qualification/records/2026-09-19-aws-run5-attempt2.md:7
  Fresh disposable target `sol-qual6-…` (same target path, <id> / us-east-1),
```

(The id is elided here on purpose: this finding is tracked, and reproducing it
would be the very leak the guard exists to prevent.)

The file's own comment explains the omission — a bare `[0-9]{12}` pattern "would
false-positive on GitHub run ids" — so the gap is a considered trade, not an
oversight. It is still a gap: the guard's stated rule is "a real-looking 12-digit
AWS account id in any tracked text file is an error", and two lines violate it
undetected.

## Why it is worth a ticket rather than a note

The failure mode is asymmetric. A *false positive* costs someone a minute of
explanation; a *false negative* is a permanent leak in a public repository, which
is what HARDEN-002 run 2 actually cost. The narrow patterns were chosen when the
only account ids in the repository were the documented placeholders; that is no
longer true.

## Not yet decided

The fix has to distinguish an account id in prose from an unrelated 12-digit
number (a GitHub run id, a timestamp fragment, a hash prefix) without becoming
noisy. Options, in rough order of preference:

1. match a 12-digit number that is *not* one of the placeholders and is adjacent
   to a qualifier (`account`, `aws`, a region token, a `::` ARN fragment), which
   is a slightly wider net than today's;
2. keep the patterns and add a one-time sweep that fails on any non-placeholder
   12-digit id in files under `internal/pipeline/`, treating those as
   qualification material where ids are expected to be redacted;
3. require the operator's own confirmation — the current position, which this
   finding records as insufficient.

Whichever is chosen, the guard should also keep the incident in view: the failure
mode it just demonstrated is an agent using `git add -A` near a qualification
target, so `internal/pipeline/audits/README.md`'s working rules should name
`git add -A` explicitly alongside the worktree rule.

## Sources

- `internal/ci/check_no_account_artifacts.sh` (rules and rationale)
- `internal/qualification/records/2026-09-18-aws-run5-attempt1.md:9`, `internal/qualification/records/2026-09-19-aws-run5-attempt2.md:7`
  (originally cited as `HARDEN-002.md:538,631`; those sections moved verbatim on 2026-09-24)
- The Run 8 findings commit, and the CI failure on PR #387
