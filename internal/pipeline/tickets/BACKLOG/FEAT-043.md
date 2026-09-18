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
