---
id: REFAC-126
type: refactor
severity: medium
title: Rework Sol_cli_port_forward -- record what Sol started instead of re-parsing /proc, and return results instead of printing and sentinels
source: operator review (2026-09-26, sol-logan-comments), cli/lib/kube/sol_cli_port_forward.ml
---

**Depends on:** REFAC-124.

## The problem

The operator's comments on `sol_cli_port_forward.ml` (325 lines) all point at the same module:

- **Hand-parsing:** "why are we hand parsing these strings? do we need an AST instead?" and "does this need to be handrolled?".
  - `read_proc_cmdline`, `parse_kubectl_pf_args` and `extract_after_prefix` reconstruct which port-forward a process is from its `/proc/<pid>/cmdline`.
  - `pid_owning_port` parses `ss`/`lsof`-style output.
  - `is_running` recognises Sol's forwarders by a substring of their args ("should we have smarter behavior for checking than this?").
- **Sentinels:** `read_last_lines` returns `""` on an unexpected error ("why not a result type"), `digits = ""`, and `stop_all`'s `[||]`.
- **Control flow:**
  - `start` uses `ignore` where a step can fail ("why ignore? I prefer let*").
  - `parse_kubectl_pf_args` is "pretty complex logic. Can we use option chaining and Results".
  - `stop_all`, `check_alive` and `detect_stale` are each "hard to understand".
  - `stop_all` "seems like it should chain a filter", with `|>`.
- **Printing in the library:** `check_alive` prints its findings ("should we be printing here or should we have an enum ... that has these results?").

## Remediation

- **Record, don't rediscover.** When Sol starts a forwarder, it writes a small record per forward (name, pid, local port, namespace, target) in its state directory. `is_running`, `stop_all` and `detect_stale` read those records and check that the pid is still the process Sol recorded, rather than parsing arbitrary processes' command lines. If an OS query for "who owns this port" is still needed, keep it in one function that returns `int option` / `result`.
- **Types, not strings:**
  - `check_alive` returns a variant (`Alive | Dead of { log_tail : string option } | Port_taken_by of int …`) and the command renders it.
  - Readers return `option`/`result`.
  - No `""` or empty-array sentinels (REFAC-123's rule).
- **`let*` chains** in `start`; `|>` pipelines with named steps in `stop_all`/`detect_stale` (REFAC-120's convention).

## Acceptance criteria

- No `/proc/*/cmdline` parsing, unless the notes justify it for a case the records can't cover, with a test.
- `git grep -n 'Printf' cli/lib/kube/sol_cli_port_forward.ml` shows no user-facing output.
- Unit tests: record round-trip; a stale record, where the pid is gone or reused, reads as not running; `check_alive`'s variants.
- `sol local up`'s port-forwards still start, and are found and stopped. Say how this was verified (live run or harness).
- Demo/example: not applicable (internal). Language parity: no impact.
