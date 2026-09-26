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

## Completion notes

- **Premise re-verified (2026-09-26):** `Sol_cli_workspace.scan` substring-greps every `dune` file under `.` and is the only input `cmd_local.ml`'s `dev_up` uses to choose infrastructure.
- **Change.** `Sol_cli_config.local_infra ~root` decides from `sol.yml` at the workspace root:
  - Kafka if a `kafka` resource is declared, Postgres if a `postgres` resource is (omitted resources don't count);
  - Loki, Prometheus and Tempo always.

  `dev_up` resolves the workspace root first; it used to scan `.`, so a run from a subdirectory scanned only that subdirectory. `scan` and its `read_file` helper are removed.
- **Before and after.** Recomputing the old grep's answer for each tracked workspace (kafka / pg / loki / prometheus / tempo):
  - pluto: 1 1 **0 0 0**
  - venus: 1 1 **0 1 0**
  - a fresh `sol new workspace`: 1 1 **0 0 0**

  Kafka and Postgres are unchanged: all three now declare both. The observability zeros were a second, hidden defect. These workspaces reach observability through `sol-svc`/`sol-obs` rather than naming `obs-*` libraries in `dune`, so `sol local infra up` never installed Loki, Prometheus, Tempo or Grafana for the canonical example or for scaffolded workspaces. "Always on" fixes that (dev mirrors prod).
- **Declarations.** The scaffold's `sol.yml` template and `internal/fixtures/venus/sol.yml` now declare `app_db: postgres` and `events: kafka`, which their services already use, as pluto does. Without that, a new workspace would have lost its Kafka and Postgres. `sol plan prod/aws/us-east-1` exits 0 for a freshly scaffolded workspace and for venus.
- **Tests** (`test_workspace.ml`, replacing the two `scan` cases):
  - declared resources decide the infrastructure;
  - **a TypeScript workspace gets its declared Postgres** (the DEC-022 gap);
  - observability is always on;
  - an omitted resource starts nothing.
- **Acceptance:** `rg -n 'string_contains ~needle:"pg-eio"' cli` returns nothing.
- **Watch in CI:** the golden-path smoke's k3d cluster now also installs the observability stack, so that job is heavier than before.
- **Verified:** `dune build` and `dune test cli/test/` pass (0 `[FAIL]`); format clean.
- **Demo/example:** pluto already declared both resources, and its infrastructure now also includes observability. The scaffold (`sol new`) and venus declare theirs.
- **Language parity (DEC-022):** closes a TypeScript gap. Local infrastructure no longer depends on OCaml build files.
