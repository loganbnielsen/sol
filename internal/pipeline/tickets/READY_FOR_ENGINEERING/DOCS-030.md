---
id: DOCS-030
type: documentation
severity: medium
title: Provide a CLI reference for every command, flag, and exit behaviour
source: docs/README.md documentation roadmap (2026-09-29)
---

**Depends on:** None.

**Related:** `docs/architecture/devops-pipeline.md` (the narrative of what each
command does), `docs/guides/TUTORIAL.md`'s CLI reference section,
`DEC-031`/`DEC-032` (the primary-axis rule the reference must present
consistently), `DOCS-026`/`DOCS-028`/`DOCS-029` (the task guides that link to
entries here).

## What this page is

A single reference for the `sol` command surface: every registered command, its
positional and flags, the scopes it accepts, and what exit status means. Today the
only reference is the tutorial's "CLI reference" comment block, which is partial
and mixes explanation with the walkthrough.

The value is not exhaustiveness for its own sake. Several rules are easy to get
wrong and hard to rediscover — which axis takes the positional, which commands
accept which scopes, and which commands are deliberately narrow (`sol logs` is
unit-only). A reference states them once.

## Audience

Any user who knows what they want to do and needs the exact spelling; and a
contributor checking that a new command follows the house rules.

## Content requirements

- **Every registered command**, grouped by primary axis: target-addressed
  (`sol deploy`, `sol up`, `sol cloud plan|apply|destroy`, `sol plan`),
  scope-addressed (`sol status`, `sol open`), and local (`sol local …`).
- For each command: the positional, the flags, accepted scopes/targets, and a
  one-line purpose.
- **Accepted scopes stated per command**, since they are deliberately not
  uniform, with the reason for the narrow ones.
- **Exit behaviour**: what a non-zero exit means, and the fail-closed cases a
  script can rely on.
- **The addressing rule**, stated once and linked from the task guides
  (`DEC-031`, `DEC-032`).
- Where a command's output has a machine-readable form (`--json`, plan output),
  say so.

## Sources of truth to link, not copy

- The command registration in `cli/bin/`.
- The axis rule: `DEC-031`, `DEC-032`.
- The narrative explanation: `docs/architecture/devops-pipeline.md`.

## Acceptance criteria

- Every command registered in `cli/bin/` appears, verified by comparing against
  the binary's own help rather than by memory.
- The reference cannot silently drift: a guard (or a test) compares the documented
  command set against the registered set and fails on a new undocumented command.
- Each command states its accepted scopes, and the rule behind the non-uniform set
  is linked.
- No command is documented with a flag it does not have; Target commands are
  marked with their ticket.
- `docs/README.md` marks this page Published.

## Notes

- Prefer generating the mechanical parts (command and flag names) from the CLI
  itself and keeping the prose curated, so drift is a test failure rather than a
  docs audit finding.
