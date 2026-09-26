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

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`17afc4b2`): `rg -n 'tm_year \+ 1900' cli --glob '*.ml'` found the six formatters listed above.

- `Sol_cli_time` (`cli/lib/base`, over `ptime`, now a dependency of `sol_cli_base`) provides `rfc3339`, `compact` and `compact_lower`. The compact forms read the real year and month from `Ptime.to_date_time`, so no caller decodes a C `struct tm`.
- All six sites use it: `cmd_alert.timestamp_now`, `Sol_cli_deployment.rfc3339_utc`, `Sol_cli_deployment_id.time_part`, `Sol_cli_run_log.generate_run_id`, and both in `Sol_cli_supervised` (the running-operation report and the operation directory name).
- **Output is unchanged.** Before writing any code I checked that `Ptime.to_rfc3339 ~tz_offset_s:0` prints the same text as the old `Unix.gmtime` formatter for `1790436649.75`: `2026-09-26T15:30:49Z`, with `Z` for UTC and the fraction truncated. `test_time.ml` pins each format for that instant, the run-id and deployment-record callers' exact shapes, and the epoch.
- **Codebase-wide** (the operator's comments are rules, not spot fixes): `rg -n 'Unix\.(gmtime|localtime|mktime)|tm_mon|tm_year' cli framework internal/tooling --glob '*.ml'` returns nothing, so no other hand-written date handling remains.
- Verification: `dune build`, `dune test cli/ --force` (62 suites, 0 failures), `internal/ci/check_ocamlformat.sh --all`.
- Demo/example: not applicable (formats unchanged).
- Language parity (DEC-022): no impact.
