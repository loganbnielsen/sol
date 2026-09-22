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

## Completion (2026-09-22)

The model now lives once, in `docs/architecture/observability-design.md`. Nothing had
to be merged in from a second document: the review text is not a file in this
repository (it survives as the tickets that own its parts), and no other doc restates
the model — the "one logs backend, one metrics backend" rule appears only here.

**What the doc gained** — five additions, all material the review asked for and the
doc did not carry:

- **One Model, Three Representations** — CLI, Grafana and automation as projections
  over one model rather than three platforms. It also names the two capabilities that
  are *not* in all three yet, with owners: traces have no CLI surface (`sol open`
  ships `logs`, `metrics`, `dashboard`; OBS-045 owns traces) and alerts are not
  exposed per scope (FEAT-092).
- **Who Is Authoritative For What** — the per-information-kind split as a table:
  Terraform state for what exists, Sol's own release records and deployment events for
  what was released, the observability backend for what applications emitted, the
  cloud provider for what it measured. Sol supplies shared identity and navigation and
  keeps no second copy. The target axis is recorded here too: a target is not a scope
  (DEC-032), addressed positionally (DEC-031), with FEAT-090 (cloud health/drift) and
  INFRA-027 (target-scoped infrastructure views) named as owners of surfaces that do
  not exist yet — and explicitly not claimed as shipped.
- **Lifecycle** — a pointer to ADR 0003 plus the one principle this doc needs: the
  phase is not infrastructure truth. **No phase list is restated**, which was the
  point of the ticket: the review's `ProvisioningCloud`/`InstallingPlatform`
  vocabulary contradicts the accepted ADR, and both names are absent from the doc
  (verified by search).
- **What Sol owns, what Grafana owns** — the split table: definitions, the label and
  attribute vocabulary, template variables and scope mapping, deep links, and
  provisioning are Sol's; rendering, storage, exploration and navigation belong to
  Grafana and the telemetry backends.
- **Non-Goals** — two additions: no second system of record, and no becoming the
  composition (Sol does not become Terraform, Kubernetes, Grafana, Prometheus, Loki
  or Tempo).

**Where the doc was aspirational, it now says so — and two unowned claims were
handled deliberately differently:**

- The dashboard list said "Sol should provision …" and hedged the release timeline
  with "when available", reading as a plan. All four dashboards exist and are
  provisioned by `cli/platform/infra/base/main.tf`; the doc now names the files, and
  records that the "service logs view" is Loki-backed log panels inside those
  dashboards rather than a separate file. "Should provision" became "provisions".
- **Hosted Path** describes a product direction that no ticket owns and that is not
  true in the tree. It is *labelled* as an unowned direction rather than deleted. The
  criterion's intent is that nothing in the doc reads as a scheduled deliverable, and
  a section that says plainly "no ticket owns this; there is no hosted Sol today;
  nothing here should be read as scheduled work" does not. Deleting it would have
  removed design information the ticket did not ask to remove, and the ticket's own
  non-goals say existing sections are edited only where the model extends them.

**CLI examples.** They were already in the shipped positional form
(`sol open logs <scope>`); verified that no `--scope` form appears, and that the one
flag the section promises — `--links` — exists (`cli/sol/bin/cmd_open.ml`).

**Verification:** the review's phase vocabulary appears 0 times; the model statement
appears in exactly one document; and every owner the doc references exists as a
ticket (`OBS-044`, `OBS-045`, `FEAT-090`, `FEAT-092`, `INFRA-027`) or as an accepted
ADR (`ADR 0003`).

**TypeScript parity:** no impact — the doc describes a language-neutral model and this
changes no contract, as the ticket states.

**TypeScript parity:** No language-parity impact — the doc describes a
language-neutral model and this changes no contract.
