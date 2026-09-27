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

## Completion notes

**Premise verified (2026-09-26):** on origin/main, `sol_cli_port_forward.ml` parsed `/proc/<pid>/cmdline`, `ss -tlnp` output and kubectl arguments, returned `""` sentinels, `ignore`d the steps of `start`, and printed from `check_alive`/`detect_stale`. `grep -cE '/proc|cmdline|"ss"|ignore|Printf.printf'` gave 12.

- **Record, don't rediscover.**
  - `start` writes a record per forward (`pf-<name>.forward`, JSON: name, namespace, target, ports) in Sol's state directory, next to the pid file.
  - `records ()` returns the recorded forwards *and* the unreadable records with why, so a corrupt record is reported, not skipped.
  - `sol local infra status` lists the records with running/stopped.
- **Liveness is a lock, not `/proc`.**
  - The wrapper takes an exclusive `flock` on `pf-<name>.lock` and holds it for its life; kubectl inherits the descriptor.
  - `is_running` is "is that lock held", which a reused pid cannot fake.
  - `stop` signals the forward's whole process group (`setsid` makes the wrapper a group leader), and only while the lock is held. This also ends the kubectl child, which the old per-pid SIGTERM could leave holding the port.
  - `stop_all` works from the records.
- **Stale forwards come from the records.** `replace_conflicting` stops the running recorded forwards on the same local port that point at a different namespace or target, and returns them for `sol up` to report. A process Sol did not start is never touched; before, any kubectl port-forward on the port was killed. `pid_owning_port`, `read_proc_cmdline`, `parse_kubectl_pf_args` and `extract_after_prefix` are gone.
- **Types, not printing.**
  - `check_alive` returns `Alive | Dead { log; log_tail : string list }`, and `sol up` renders it with the same text as before.
  - `start` is a `let*` chain returning `(unit, string) result`: the record, the script, `Unix.chmod` instead of a `chmod` process, the spawn. Callers print a warning on `Error`.
  - `git grep -n 'Printf.printf\|Printf.eprintf\|print_' cli/lib/kube/sol_cli_port_forward.ml` prints nothing.
- **A race found on the way.**
  - `is_running` probes by taking the lock for an instant, so a probe landing on the new wrapper's `flock -n` made the wrapper exit. A `sol local infra status` or `sol up` check racing a starting forward could kill it.
  - The wrapper now waits up to 2 s for the lock (`flock -w 2`), and logs when it declines to start a second copy instead of exiting silently.
  - Found by the end-to-end test failing about one run in three under dune's parallel load. After the fix: 0 failures in 10 full-suite runs.
- **Tests** (`test_port_forward.ml`; it refuses to run without dune's private `XDG_DATA_HOME`, so it cannot touch the operator's state):
  - record round trip; a corrupt record is reported;
  - liveness is the lock; a reused pid is never signalled;
  - `replace_conflicting` stops only the running forward for another target on the port;
  - a dead forward reports its log tail;
  - end to end: the real wrapper with a fake kubectl, where `start` makes it running and recorded, and `stop` ends the wrapper and its kubectl.
- **Not verified live** against a k3d cluster. The end-to-end test runs the real wrapper script, but a live `sol local infra up` was not run in this session.
- 67 CLI suites pass; format is clean; the offline lifecycle harness passes.
- **Demo/example:** not applicable (internal). **Language parity:** no impact.
