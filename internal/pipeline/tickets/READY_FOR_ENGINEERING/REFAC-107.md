---
id: REFAC-107
type: refactor
severity: medium
title: Drive local infrastructure from the parsed workspace model, not a substring grep of dune files
source: operator code-review notes (2026-09-26), cli/lib/workspace/sol_cli_workspace.ml `scan`
---

**Depends on:** None.

## The problem

`sol local infra up` decides which infrastructure to start with `Sol_cli_workspace.scan` (`cli/lib/workspace/sol_cli_workspace.ml`, called from `cli/bin/cmd_local.ml:210`). It walks every directory and substring-greps each `dune` file for library names: `kafka-eio-service`, `pg-eio`, `obs-loki-eio`, `obs-prometheus-eio`, `obs-tempo-eio`. That has two defects:

1. **TypeScript workloads are invisible.** A TypeScript unit has no `dune` file, so a TypeScript-only workspace starts no Kafka and no Postgres. That's a DEC-022 parity gap in the local golden path.
2. **It infers what `sol.yml` already declares.** Resources are declared in `sol.yml` (`app_db: type: postgres`, `events: type: kafka`), and a grep over build files can disagree with that declaration. It is also fragile: a comment or an unused dependency counts.

## Remediation

- Decide local infrastructure from the parsed workspace model: `sol.yml`'s declared resources (postgres → Postgres, kafka → Redpanda) plus the units discovery already finds.
- Start the observability stack (Loki, Prometheus, Tempo) unconditionally. Every production platform install has it ("dev mirrors prod"), so a local cluster without it is a divergence, not a saving.
- Remove `scan` and its `requirements` record, and anything else only it uses.

## Acceptance criteria

- A TypeScript-only workspace that declares a postgres resource gets Postgres from `sol local infra up`. There's a test on the decision function.
- An OCaml workspace gets the same infrastructure as before for pluto. Show the before and after decision.
- No `dune`-file grep remains for this purpose: `rg -n 'string_contains ~needle:"pg-eio"' cli` returns nothing.
- **Demo/example:** pluto's `sol local infra up` still brings up what it needs. State how that was checked.

## Completion notes (required)

- Language parity (DEC-022): this *closes* a TypeScript gap; say so.
