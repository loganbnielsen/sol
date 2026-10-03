---
id: FEAT-043
type: feature
severity: low
source: architecture discussion 2026-09-09 (workspace direction review)
---

**Depends on:** None.

Decide whether automatic export of application data to an analytics warehouse (e.g. Databricks) is a Sol product surface, a documented escape-hatch connector, or out of scope.

## Problem

There is currently nothing in the repo for analytics or warehouse export (`rg -i "databricks|warehouse|data lake|snowflake|bigquery" docs cli framework packages` finds only an unrelated `analytics_db` resource-name example). Running business analytics and controls over app data therefore requires the user to build their own pipeline, which is a large amount of undifferentiated work.

At the same time, a managed export surface is a different company shape from "run the same factory for you": it brings CDC, schema evolution, PII handling, governance, retention, and cost ownership. Building it speculatively risks a second product before the self-hosted factory path is proven, and sits awkwardly against the FOSS/no-lock-in principle.

## Goal

A decision, not code: is this core, a connector, or deferred?

## Remediation

- Timebox a discovery spike covering: CDC from Postgres (logical replication/Debezium vs periodic export), whether to reuse existing Kafka topics as the transport, schema evolution, PII/governance controls, and whether Databricks specifically is the right first target versus generic object storage.
- Compare against the FOSS/no-lock-in principle and the "self-hosted first" product bias.
- Produce a DEC ticket with a recommendation and rough scope; do not ship production code from this ticket.

## Acceptance criteria

- A DEC ticket exists with a recommendation (build / connector / defer) and rationale.
- No production implementation is added under this ticket.

## Disposition (2026-10-03) — decision required

Smallest decision: is analytics/warehouse export a Sol product surface, a documented escape-hatch connector, or out of scope? Options: a timeboxed discovery spike toward a DEC (build connector), or declare it a non-goal. Consequence: a managed export surface is a second product (CDC, schema evolution, PII, governance, cost).

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.


## Decision (2026-10-03) — out of the alpha

Operator decision: **None — declare all out of the alpha.** Analytics/warehouse
export is not pursued for the current alpha. Deferred with a trigger rather than
closed, so the record survives: reconsider when a real workload demonstrates a
business-analytics need over app data that Postgres plus the event stream cannot
serve, or when a customer requires a governed export surface.

Reconsideration trigger: a concrete workload or customer requirement for
warehouse export with CDC, schema-evolution, PII/governance and cost ownership
scoped as its own product surface.
