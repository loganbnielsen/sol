---
id: REFAC-159
type: refactor
severity: medium
title: Make `soldev pipeline merge` match the auto-merge-default policy
source: PR #758 (2026-09-29) — the agent surface made auto-merge the documented default, and the tool still defaults to an immediate merge
premise: "! rg -q 'use --auto to wait on GitHub' internal/tooling/soldev/bin/cmd_pipeline.ml"
---

**Depends on:** None.

**Related:** `AGENTS.md` § *Shepherding PRs to merge* and the *Landing a PR* calibration
row (the policy this aligns with), `CONTRIBUTING.md` § *Merge*, PR #758 (the docs
change), `FEAT-115` (the ticketless-PR targeting gap in the same command),
`BUG-038` (`merge-finish`'s commit that branch protection always refuses).

## Premise

Checked 2026-09-30 at `origin/main` `488741f4`. The probe is stale exactly when the
old framing is gone from the command's help.

## The gap

`AGENTS.md` now says auto-merge is the default and an immediate merge is the
exception. The command does the opposite, and its own help says the opposite:

- `internal/tooling/soldev/bin/cmd_pipeline.ml:25-30` — `--auto` is an `Arg.flag`
  (default `false`), so `soldev pipeline merge <id>` merges immediately.
- `internal/tooling/soldev/bin/cmd_pipeline.ml:41` — the `merge` doc reads
  "use `--auto` to wait on GitHub", framing auto-merge as the unusual path.
- `internal/tooling/soldev/lib/soldev_merge.ml:115`, `:486` — `auto_merge` defaults
  `false` and selects "merge" versus "auto-merge".

So an agent that reads the tool's own help gets the opposite of the documented
policy, and the policy only holds while every caller remembers to pass `--auto`. The
instructions and the tool disagree, which is the kind of friction the calibration
section says to repair in place rather than document around.

## Remediation

Preferred — make the tool's default action agree with the policy:

- `soldev pipeline merge <id>` queues native squash auto-merge (today's `--auto`
  behavior).
- A new `--immediate` (or `--no-auto`) opt-in performs today's immediate merge, and
  still only when required CI is already green.
- Decide whether `--auto` stays as an accepted no-op alias or is dropped. The repo is
  pre-alpha and this is internal tooling, so a clean break is allowed; an alias is
  cheap and keeps any existing invocation working. Pick one and say why.
- Update the `merge` and `--auto` doc strings to describe the default and the
  opt-out.
- Leave the non-draft and prerequisite checks, head pinning, and the no-admin-bypass
  rule unchanged.

Fallback, if the operator would rather the tool keep today's behavior: fix the help
text and have `AGENTS.md` name the flag explicitly. That is the weaker option — the
tool would still contradict "auto-merge is the default".

## Non-goals

- Not a change to merge mechanics: head-pinned squash, no admin bypass, no worktree
  cleanup, and prerequisite gating are unchanged.
- Not the ticketless-PR targeting gap; that is `FEAT-115`.
- Not `merge-finish`, `check-reverts`, or `pipeline submit`.

## Acceptance criteria

- `soldev pipeline merge <id>` queues auto-merge without requiring `--auto`.
- The immediate path is reachable only by an explicit opt-in and still requires green
  required CI.
- `soldev pipeline merge --help` describes the default and the opt-in, with no
  leftover "use `--auto` to wait on GitHub".
- Any existing invocation that relied on the old default is either preserved or the
  change is stated in the PR/release notes; no silent break of a documented command.
- A test covers the queued path, the immediate path, and the default.
- `AGENTS.md` and `CONTRIBUTING.md` agree with the shipped behavior.

**Demo/example coverage:** Not applicable — internal maintainer tooling with no
app-author surface. State that in the completion notes.

**TypeScript parity:** No language-parity impact — `soldev` is maintainer tooling,
not part of the application contract.
