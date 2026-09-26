---
id: REFAC-119
type: refactor
severity: low
title: Format timestamps with ptime instead of six hand-written Unix.tm formatters
source: operator code-review notes (2026-09-26, sol-logan-comments), cli/bin/cmd_alert.ml timestamp_now
---

**Depends on:** None.

## The problem

`rg -n 'tm_year \+ 1900' cli --glob '*.ml'` finds six copies (2026-09-26): `cmd_alert.ml`, `sol_cli_run_log.ml`, `sol_cli_deployment.ml`, `sol_cli_supervised.ml` (twice) and `sol_cli_deployment_id.ml`. They are C-struct arithmetic (years since 1900, zero-based months) that the reader has to decode. `ptime` is already a CLI dependency (`cli/lib/kube`).

## Remediation

One `Sol_cli_time` in `cli/lib/base` over `ptime`, covering RFC 3339 and the compact forms used for directory and id names. All six sites use it, and every format stays byte-for-byte the same.

## Acceptance criteria

- `rg 'tm_year \+ 1900' cli` returns nothing.
- Tests pin each format's exact output for a fixed instant.
- Demo/example: not applicable; state it.
