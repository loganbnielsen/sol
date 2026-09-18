---
id: INFRA-010
type: feature
severity: medium
source: verification pass 2026-09-11 — four findings were premised on work that had already shipped
---

**Depends on:** None.

Stop tickets whose premise has gone stale from looking actionable. Nothing in this pipeline notices when the work a finding describes has already been done.

## What happened

A single verification pass found four separate findings premised on work that already existed:

- The ROADMAP's "deploy & runtime visibility" paragraph listed four items as "not yet ticketed"; three were implemented (Kubernetes-derived diagnosis via OBS-001, `sol logs` fallback, pod-stdout collection via Alloy).
- `EXP-021` claimed `sol deploy` printed no service URL and `sol status` no image — both fixed, according to *its own review note*, and by the golden-path smoke output.
- `EXP-023` claimed nothing told the user to run the `kubeconfig` command — documented in the tutorial and now run automatically.
- `EXP-024` claimed `sol logs` failed for `-fn` — handled, with a unit test asserting the `fn` target argv.

None of this is anyone's carelessness. A ticket is written at discovery time and then never re-read; the code moves faster than the backlog; and an open ticket looks identical whether its premise still holds or not. The cost is real: a planning pass came within a decision of scheduling a week of already-built work.

## Why time-based nagging is the wrong fix

Warnings on "ticket older than N days" fire on genuine open work as often as on stale work, so they get ignored. The signal that matters is not age, it is *whether the thing the ticket says is missing still is*.

## Recommended mechanism

**A declarative premise probe, evaluated by `soldev pipeline check`.**

Frontmatter on a ticket gains an optional probe — a command that *succeeds when the premise is stale*:

```yaml
premise: "rg -q 'fallback_to_kubectl' cli/sol/bin/cmd_logs.ml"
```

`pipeline check` and `pipeline ls` run it and mark the ticket `premise-stale` rather than `actionable`, with the probe's output shown. Three properties make this worth doing:

- It is cheap: most findings name a symbol, file or command whose existence is the premise.
- It is honest: the probe is a statement about the code, visible in the ticket, and reviewable.
- It fails closed in the useful direction — a probe that cannot be run reports "unverified", not "fine".

Complement it with the convention, for findings that cannot be expressed as a probe: **before starting any non-`DONE` ticket, verify its premise and record the verification in the ticket** (one line, with what was checked). Both stale findings closed on 2026-09-11 were resolved in under a minute each — the cost is small, and it is only paid once per ticket.

## Scope

- Optional `premise:` frontmatter, with the probe convention documented (succeeds ⇒ premise no longer holds).
- `pipeline check` / `pipeline ls` evaluate it and report `premise-stale` or `unverified` distinctly from `actionable`, without breaking existing tickets that have no probe.
- The re-verification convention recorded where tickets are written — the ticket-writing guidance and the audit skills.

## Acceptance criteria

- A ticket with a probe whose command succeeds is reported as `premise-stale`, and is not presented as actionable work.
- A ticket with an unparseable or failing-to-run probe is reported as `unverified`, never silently as actionable.
- Tickets without a probe behave exactly as they do today.
- The convention appears in the guidance used when filing tickets, not only in this decision record.

## Completion notes

**All four criteria are met, verified end-to-end with three throwaway tickets rather than only by unit tests.** A probe that succeeds reports `status: premise-stale`; one that fails reports `premise: holds` and leaves the ticket `actionable` (unchanged behaviour); one that cannot run (exit 127) reports `status: premise-unverified`. The listing shows `premise-stale`, `actionable` and `premise-unverified` in its label column for the same three.

**The inversion is pinned deliberately.** The probe succeeds when the premise is *stale*, because the natural form would require every probe to be negated and a mis-negated probe fails in the direction of "still actionable" — the exact failure this exists to catch. Seven unit tests cover it, with the exit code injected so nothing is executed.

**`ls` evaluates probes too**, not only `check`. That was the harder call: running shell as a side effect of a listing is a surprise, but the listing is precisely where a stale ticket silently looks like work, so evaluating only in `check` would miss the case the ticket was filed about. `ls` is already not a pure read (it queries `gh` for open PRs), and it suppresses the echo since it prints a table; `check` echoes the command before running it. Both facts are recorded in the guidance, along with the rule that the probe is shell supplied by whoever wrote the ticket — read it before letting it run — and should be cheap and read-only, since `ls` runs it.

**Fail-open direction.** A probe that cannot run (126/127) or is declared empty is `unverified`, never `holds`: an unverified premise is a call to check by hand, not a licence to start.

**Quoting.** `premise_of` strips surrounding quotes, because the convention quotes a probe containing a colon and the frontmatter parser need not — documenting one form and parsing the other is how a convention becomes a trap.

**Guidance updated** in `.claude/CLAUDE.md` (the ticket-writing section), including the re-verification convention for findings that cannot be expressed as a probe.
