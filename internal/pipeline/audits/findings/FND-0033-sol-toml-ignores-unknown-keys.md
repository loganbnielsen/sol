# FND-0033 — `sol.toml` silently ignores unknown keys and tables, so a typo drops the setting

- **Classification:** `DESIGN_GAP`. The design question is already decided, so it
  carries a ticket (README: a decided `DESIGN_GAP` becomes concrete work).
- **State:** `OPEN`
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `BUG-042`
- **Evidence class:** `MECHANISM` (probe below)

## What is established

`cli/sol/lib/sol_cli_toml.ml:1-2`: *"Unknown keys/sections are forward-compatible;
malformed TOML raises Parse_error."* `load_result` (`:613`) reads each known path with
`find_*_opt`. Anything else in the document is never looked at.

### Reproduction (run 2026-09-23)

The probe links `sol_cli` and calls `Sol_cli_toml.load_result` on each file:

```text
control: [infra.scale] replicas = 3      -> Ok replicas=3 rollout=None
typo key: [infra.scale] replica = 3      -> Ok replicas=None rollout=None
typo table: [infra.sacle] replicas = 3   -> Ok replicas=None rollout=None
typo table: [infra.rolout] strategy      -> Ok replicas=None rollout=None
wrong type: replicas = "3"               -> Error: ... value must be an integer, found string
control: [infra.rollout] strategy        -> Ok replicas=None rollout=Some
```

A wrong *type* fails loudly. A wrong *name* is indistinguishable from not having
written the setting at all. The fields affected are the ones an app author uses to
state production posture: `replicas`, `availability`, `cpu`/`memory`, `env.secrets`,
`volumes`, `rollout`, `ingress_*`, `[service] schedule` (see FND-0034) and
`scheduled_concurrency`.

## Why the design question is already decided

- The stated reason is **forward compatibility**. The repo's pre-alpha policy
  (AGENTS.md; `~/Code/CLAUDE.md`) makes compatibility a non-constraint.
- The sibling config, `sol.yml`, was hardened to *"fail-loud unknown keys"* by
  FEAT-025/FEAT-028 (`sol_cli_config.ml:480, 531, 655, 686, 732, 760`). The two
  files an app author writes now follow opposite rules.
- AUDIT-033 replaced the hand-rolled parser with otoml because the old one "silently
  ignores many malformed shapes", and then kept that behaviour for names.

## Impact

Medium. A misspelled `availability`, `replicas` or `rollout` table deploys with the
default posture, and the profile preflight validates the default rather than what the
author wrote. The author gets no signal at any stage.

## Remedy shape

After reading known keys, walk the document and reject any key or table not in the
schema (per section: `[infra.scale]`, `[infra.env]`, `[infra.volumes.<name>]`,
`[infra.deploy]`, `[infra.labels]`, `[infra.rollout]`, `[service]`). Name the unknown
key and the file. Scaffolded `sol.toml` files must still load, which is a test to add.

## Related

FEAT-025 / FEAT-028 (`sol.yml` precedent); AUDIT-033 (parser replacement); FND-0034.
