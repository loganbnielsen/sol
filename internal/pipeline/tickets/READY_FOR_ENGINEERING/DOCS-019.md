---
id: DOCS-019
type: docs-finding
severity: medium
title: Land the unified operational interface as the single model doc
source: Sol Unified Operational Interface design review, 2026-09-18
---

**Depends on:** None.

**Related:** DEC-031, DEC-032, OBS-045, OBS-046, FEAT-090, FEAT-092, INFRA-027, ADR 0003.

## What this is

Land the "Sol Unified Operational Interface" material as the normative model,
*inside* `docs/architecture/observability-design.md` rather than as a second
architecture document beside it. The two overlap heavily — same identity labels,
same "one workspace -> one logs backend" rule, same dashboard shape, and
near-identical non-goals — and two docs stating one model is the exact failure
the model itself forbids.

The review content that `observability-design.md` does **not** already carry:

- the multi-representation statement (CLI / Grafana / automation are projections
  over one model, not separate platforms);
- the authority split per information kind — Terraform state, Sol release
  records, and observability systems each stay authoritative for their own facts,
  and Sol supplies the shared identity and navigation;
- a **pointer** to the target lifecycle model, not a copy of it. ADR 0003
  (`docs/architecture/adr/0003-lifecycle-phases-authority-and-policy.md`) is
  Accepted and already defines the phases, per-phase authority, desired-state
  policy, allowed mutations and the "phase is not infrastructure truth" boundary.
  The doc references it and states the principle; it does not restate a phase
  list;
- the explicit split of what Sol owns (dashboard definitions, telemetry
  labels/attributes, variables, scope mapping, deep links, provisioning) versus
  what Grafana owns (rendering, exploration, time-series navigation);
- the open-source composition philosophy — Sol does not become Terraform,
  Kubernetes, Grafana, Prometheus, Loki, or Tempo.

Everything else in the review is already true or already written down. This
ticket constrains *where* the material lands and forces each claim to have an
owner; it is not a licence to restate the whole document as new work.

## Evidence (2026-09-18, `main` at 790dc3e8)

`docs/architecture/observability-design.md` already states:

| Claim in the review | Already present |
|---|---|
| identity labels are the API; namespaces/pods/Helm names are implementation details | §Identity |
| one workspace -> one logs backend, one metrics backend, one dashboard surface | opening rule |
| backend mode changes storage/transport, not the product surface | §Backend Modes |
| Grafana is the visual surface; Sol owns definitions, scope mapping and links | §Dashboard Shape |
| no bespoke frontend, no fork/white-label, no UI-only capability | §Non-Goals |
| managed-resource dashboards keyed `resource/<type>/<name>` | §Managed resource dashboards (OBS-044) |

The lifecycle is **not** a new claim to import. ADR 0003 was accepted on
2026-09-18 and already carries a phase vocabulary that differs from the review's
draft: `CloudBootstrap`, `PlatformInstalling`, `Ready`, `PlatformUpdating`,
`PreparingDestroy`, `Destroying` — not the review's
`ProvisioningCloud`/`InstallingPlatform` sequence. Copying the review's names
into the doc would create a second, contradictory statement of an already-decided
model, which is precisely the failure this ticket exists to prevent. The review's
lifecycle section becomes a pointer plus the principle it illustrates
(a phase determines authority and applicable policy; it does not determine what
infrastructure exists).

The review's remaining genuinely new claims are the multi-representation
statement, the per-information-kind authority split, the phase-is-not-truth
boundary, the Sol-owns/Grafana-owns split, and the composition non-goals. Each is
either decided by DEC-031/DEC-032 or implemented by OBS-045, OBS-046, FEAT-090,
FEAT-092, INFRA-027.

The four application dashboards the review's "Dashboard Shape" section describes
already exist as files
(`cli/platform/infra/base/dashboards/{workspace-overview,domain-overview,service-template,release-timeline}.json`,
wired in `cli/platform/infra/base/main.tf`), so that section is confirmation, not
a gap.

## Non-goals

- Not a rewrite of `observability-design.md`; existing sections are edited only
  where the model extends them.
- Not a new `docs/architecture/unified-operational-interface.md`.
- Not a second statement of the lifecycle model. ADR 0003 owns it; this doc
  points at it.
- Does not decide the open shapes (scope-flag shape, target scope). Those are
  DEC-031/DEC-032, and this ticket must not pre-empt them by stating an answer in
  prose.
- No capability is documented that no ticket owns.

## Acceptance criteria

- `docs/architecture/observability-design.md` states the model once, and gains
  the multi-representation section, the per-information-kind authority split, a
  reference to ADR 0003 for the lifecycle (with no second phase vocabulary), the
  Sol-owns/Grafana-owns split, and the composition non-goals.
- The review's `ProvisioningCloud`/`InstallingPlatform` names do not appear in
  the doc; the accepted ADR 0003 names do, or the phase list is simply not
  restated.
- Every claim in the doc that is not yet true in the tree names the ticket that
  owns it, in the doc itself. A claim with no owner is deleted rather than left
  aspirational.
- No second architecture document restates the same model; if the review text is
  retained anywhere it is a pointer to this doc.
- The review's CLI examples match the shape the CLI actually accepts. Until
  DEC-031 resolves the scope-flag question they are written in the shipped
  positional form (`sol open logs <scope>`), not the review's
  `sol open --scope <scope> --logs`.

**Demo/example coverage:** Document-only change; no runnable example or demo
applies, and that will be stated in the completion notes.

**TypeScript parity:** No language-parity impact — the doc describes a
language-neutral model and this changes no contract.
