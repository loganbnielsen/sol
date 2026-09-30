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
app-author surface, so there is no runnable example to update.

**TypeScript parity:** No language-parity impact — `soldev` is maintainer tooling,
not part of the application contract.

## Completion

**Premise re-verified before implementing.** Checked 2026-09-30 at `origin/main`
`24f45f43` — main has moved since the ticket recorded `488741f4`, so the probe was
re-run rather than trusted. All three claims still held: the `merge` doc read "use
`--auto` to wait on GitHub", `--auto` was an `Arg.flag` with no default, and
`soldev_merge.ml` chose "merge" versus "auto-merge" from that boolean. The probe now
succeeds, which is what completion of this ticket means.

**`--auto` is dropped, not aliased.** An alias is the one option `AGENTS.md` rules
out: pre-alpha, no compat shims or deprecated aliases. So `soldev pipeline merge
--auto <id>` now fails as an unknown option — a loud break at the call site, in the
same change that moved the default — and every in-repo caller was updated here:
`AGENTS.md` (the auto-merge-default paragraph, the `pipeline merge` role, and
§ *Shepherding PRs to merge*), `CONTRIBUTING.md` § *Merge*, and the `work` and
`self-review` skills. The old ordinary invocation, `soldev pipeline merge <id>`,
keeps its spelling and becomes today's `--auto` behaviour, which is the intent.

**What changed.** `merge_mode` (`Auto_merge` | `Immediate`) replaces the boolean
through `merge_command`, `merge_candidates` and `run_merge`; `merge_command` emits
` --auto` unless the mode is `Immediate`. Green required checks now has one
definition — `check_buckets_of_json` plus `buckets_green`, shared by
`checks_green_of_json` and the new tri-state `required_checks`. The ticket and sweep
paths keep their gates exactly: a test pins that queueing a ticket consults no checks
at all (no `gh pr checks` call), and `--immediate` still requires green required CI.
Non-draft, prerequisite, head-pin and no-admin-bypass behaviour are untouched.

**Validation:** `dune build` clean. `internal/tooling/soldev/test/test_merge.exe` —
18 tests, 4 rewritten or added (the default mode and the opt-in, the pinned
head-merge command, and the no-checks-consulted pin). Two mutations were run against
the suite and each failed it for the reason under test: flipping the default mode to
`Immediate`, and making the default skip `--auto`. `soldev pipeline merge --help` was
re-read: it names the default and the opt-in and no longer contains "use `--auto` to
wait on GitHub". Full required CI on the PR head.

**Remaining limitation:** none known. `merge-finish`, `check-reverts` and
`pipeline submit` are untouched.
