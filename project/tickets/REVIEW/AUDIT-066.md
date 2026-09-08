---
id: AUDIT-066
type: audit-finding
severity: medium
source: project/audits/2026-09-08_audit.md
branch: AUDIT-066/refresh-stale-paths
worktree: /home/lbendtly/Code/sol-AUDIT-066-refresh-stale-paths
pr: https://github.com/loganbnielsen/sol/pull/155
---

`docs/audits/AUDIT.md` template still uses pre-rename `sun` naming throughout

**Description:** The repo was renamed `sun` → `sol` (CLI binary, `framework/sol-*` packages, `Sol.Service.Make`/`Sol.Worker.Make`/`Sol.Fn.Make`, `sol.yml`/target-file config) per `.claude/CLAUDE.md`, but `docs/audits/AUDIT.md` — the reusable checklist template `/audit` works through every run — was never updated. It still names `cli/sun/bin/`, `cli/sun/lib/sun_cli_scaffold.ml`, `cli/sun/lib/sun_cli_manifest.ml`, `integrations/kafka/kafka-eio-core/...` (Kafka core/consumer/producer moved to the external `~/Code/kafka-eio` package with a flat `lib/` layout), `framework/sun-worker/lib/worker.ml`, `Sun.Service.Make`, and `sun.toml` as the config file (superseded by `sol.yml` + `sol/<env>/<provider>/<region>.yml`).

**Impact:** Every future `/audit` run has to manually re-derive current paths before checking anything, costing time and risking a false PASS/FAIL if a path is guessed wrong instead of verified. This is exactly the class of gap Section 9 of the audit itself asks to catch ("Spec files match implementation reality") — the audit's own template fails its own invariant.

**Remediation:** Update `docs/audits/AUDIT.md`'s source-location references and prose to the current layout: `cli/sol/bin/` · `cli/sol/lib/sol_cli_scaffold.ml` · `cli/sol/lib/sol_cli_manifest.ml` + `sol_cli_manifest_yaml.ml`; note Kafka core/consumer/producer now live in the external `~/Code/kafka-eio` package (flat `lib/kafka_stubs.c`, `lib/kafka_consumer.ml`); `framework/sol-worker/lib/worker.ml`; `Sol.Service.Make`/`Sol.Worker.Make`/`Sol.Fn.Make`; and replace `sun.toml` references with the current `sol.yml`/target-file model. Keep the file as a reusable template — just point it at what exists today.
