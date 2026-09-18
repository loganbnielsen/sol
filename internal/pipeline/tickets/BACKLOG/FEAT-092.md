---
id: FEAT-092
type: feature
severity: low
title: Show which alerts apply to a Sol scope
source: Sol Unified Operational Interface design review, 2026-09-18
---

**Depends on:** None.

**Related:** DOCS-019, DEC-031, DEC-032, OBS-043, FEAT-090.

## Decision Required

This ticket is allowed to resolve to "no change", and that resolution is the
first thing to decide:

1. **Build it** — a scope-aware view of the alerts that apply to a scope, using
   the same identity labels the metrics use, with each alert's owner and runbook
   surfaced.
2. **Declare it a non-goal** — on the grounds that alert *definitions* and
   *firing state* are Grafana/Alertmanager's authority, and Sol should link to
   them rather than model them. That is the review's own "Grafana owns
   rendering" position applied to alerting, and it is a defensible answer.

If (2), this closes as a documentation change via DOCS-019, not as code. The
ticket stays in `BACKLOG/` until the decision is recorded.

## What this is

The review lists "relevant alerts" as part of observability at unit, domain and
target scope. Sol has an alert-delivery contract already — `Sol_cli_alerting`
(OBS-043: receiver type and endpoint, owner, runbook URL) — plus `sol alert test`
to prove the route end to end and `docs/deployment/alert-runbooks.md` for the
operational side. What does not exist is any way to see, from Sol, which alerts
apply to a given scope. The user is expected to already know which rules concern
them.

## Evidence (2026-09-18, `main` at 790dc3e8)

```text
$ sol alert --help | sed -n '/COMMANDS/,/COMMON/p'
       test […]   Exercise the alert-to-owner response loop
```

`sol alert` has exactly one subcommand and it is about proving delivery, not
about showing what would fire. `sol status` has no alerts section at any scope
(`cli/sol/bin/cmd_status.ml` prints Domains / Observability / Open / Namespace
blocks only).

The declaration side is real, so a view would have something to resolve against:
a target declares `alert_receiver_type`, `alert_receiver_url`, `alert_owner`, and
`alert_runbook_url`, validated by `Sol_cli_alerting.validate` and carried into
the platform by `Sol_cli_cloud_lifecycle.platform_inputs`.

## Non-goals

- Not alert routing or delivery — OBS-043 and HARDEN-002 own that.
- Not an alert-rule authoring surface, and not a replacement for Alertmanager's
  UI.
- Not a second copy of rule definitions. Sol does not become the authority for
  which rules exist; if built, the view resolves them from where they live.
- Not a new command family — any new view belongs to the axis DEC-032 defines.

## Acceptance criteria

- The decision (build or non-goal) is recorded here, with its reason.
- If built: the view resolves alerts for workspace, domain, and unit scope from
  the identity labels, names each alert's owner and runbook, and degrades to an
  explanation — not an empty list — when no alert source is configured.
- If built: an advanced user can still reach the underlying alerting UI from the
  same entry point.
- If closed as a non-goal: DOCS-019's doc states why, so the next reader does not
  re-file it.

**Demo/example coverage:** If built, `examples/pluto` must demonstrate it against
the demo workspace's configured alert owner and receiver. If closed as a
non-goal, the doc change is the deliverable and no demo applies — stated in the
completion notes.

**TypeScript parity:** No language-parity impact — alert routing is declared at
the target level and is shared by all languages.
