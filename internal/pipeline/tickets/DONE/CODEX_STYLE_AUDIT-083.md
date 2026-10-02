---
id: CODEX_STYLE_AUDIT-083
type: refactor
severity: medium
source: internal/pipeline/audits/STYLE_AUDIT.md
premise: '! rg -q "^let wrapper_script" cli/lib/kube/sol_cli_port_forward.ml'
---

Move the port-forward retry policy out of a generated /bin/sh script

**Depends on:** None.

**Problem.** `cli/lib/kube/sol_cli_port_forward.ml` runs each port-forward as a
generated shell program. `wrapper_script` (`:113`) emits a `/bin/sh` script
that owns the whole policy:

- `max_fail_streak` (`:110`) and `quick_fail_threshold_s` (`:111`) become shell
  literals (`fails=$((fails + 1))`, `[ $((t1 - t0)) -lt 5 ]`);
- the retry loop, the give-up message and the `flock` "already running" branch
  are string templates (`:125-155`);
- `start` (`:159`) writes it, `Unix.chmod`s it 0o755, and launches it through
  `Sol_cli_process.run_shell` with `setsid ... &`.

The result is a lifecycle policy that OCaml cannot type, test, or reuse: the
give-up rule is only observable by running a shell script and reading a log,
and the module's `spec` record (which already serialises through
`record_json`/`spec_of_json`, `:9-38`) is not what the running process reads.
`cli/test/inline/test_port_forward.ml` can only test the record and registry
helpers, not the retry behaviour.

The repo already has the right shape for a process that must outlive the CLI:
`Sol_cli_supervised` (`cli/lib/cloud/sol_cli_supervised.ml`) forks, `setsid`s,
and re-execs the binary in a hidden `__supervise` mode dispatched from
`cli/bin/main.ml:3` through `dispatch_if_supervisor`.

**Goal.** A hidden `sol __port-forward <name>` supervisor mode that reads the
existing record file, runs `kubectl port-forward` in a loop and owns the fail
streak / quick-failure threshold as typed OCaml constants, appending to
`Sol_cli_state.log_file` and writing the pid via `Sol_cli_state.pid_file`.
`start` should record the spec and fork+`setsid`+exec the supervisor (the
`Sol_cli_supervised.run` shape) instead of generating a script. `is_running`,
`stop`, `records` and the host-side record format stay as they are.

**Acceptance criteria:**

- `rg -n "#!/bin/sh|wrapper_script" cli/lib/kube/sol_cli_port_forward.ml`
  returns nothing.
- The fail streak, the quick-failure threshold and the give-up decision are
  OCaml values with a unit test that drives them directly (give up after N
  quick failures; reset the streak after a long-lived run), without launching a
  shell.
- The lock behaviour is preserved: a second `sol` process does not start a
  second port-forward for the same name and exits 0 with the existing message.
- `sol local up` smoke still reaches the forwarded service (or the ticket
  records that the local up path was exercised manually and how).
- Full `dune build`; `dune fmt` clean; `cli/test/inline` passes.

## Completion (2026-10-02)

- **Premise re-verified** at `origin/main` `c877efa5`: `wrapper_script` emitted a `/bin/sh` program with the `flock` branch, the `date +%s` timing and the fail-streak loop, and `start` wrote and `setsid`-launched it.
- **Fix.** The policy is now typed OCaml in `sol_cli_port_forward.ml`: `max_fail_streak`, `quick_fail_threshold_s`, `next_fail_streak ~streak ~elapsed_s` and `exhausted`. `supervise ~name ~context` reads the record, takes the lock (2s retry), logs `already running` and exits 0 if another holder has it, writes its own pid, and loops `kubectl --context … port-forward` through `Sol_cli_process.spawn ~output:Unix.stdout` + `join`, exiting 1 with the give-up message once the streak is exhausted. `dispatch_if_supervisor` handles `sol __port-forward <name> <context>` and is called from `cli/bin/main.ml` beside the Terraform one. `start ?supervisor` forks, `setsid`s, redirects to the log and `execve`s the binary — no generated script.
- **Lock primitive, stated explicitly.** The supervisor must hold the lock for its lifetime, and OCaml has no `flock(2)` binding, so liveness moved from `flock -n` (shell) to `fcntl` (`Unix.lockf`), the same primitive on both sides: `is_running` takes `F_TLOCK` and releases it, so "running" still means exactly "the lock is held". `stop`, `records`, `check_alive` and `replace_conflicting` are unchanged in behaviour.
- **Supporting changes.** `Sol_cli_process.join : background -> unit` was added as `spawn`'s wait counterpart, so the supervisor keeps spawning behind the single runner (`check_single_runner.sh` initially rejected a direct `Unix.create_process`); `Sol_cli_state.script_file` is deleted as now dead.
- **Tests (targeted lifecycle coverage).** `test_port_forward.ml`: `hold_lock` now takes the fcntl lock in a forked child, so every liveness/stop/replace-conflicting test exercises the new primitive; a new policy test drives the streak, its reset on a long-lived run, the exact-threshold boundary and the give-up limit; the end-to-end `start`/`stop` test now launches the real `sol` binary as the supervisor (located from the build directory or the source root) with a fake `kubectl` on `PATH`, and still asserts the lock goes live, the record exists, `stop` ends the group and the child `kubectl` dies.
- **`sol local up` smoke: not run.** No Kubernetes cluster is reachable from this environment (`kubectl` is pinned to an EKS context that does not resolve), so the live path could not be exercised; the hermetic end-to-end `start`/`stop` test above is the substitute coverage, and the path is recorded here rather than claimed.
- Full `dune build`; `dune fmt` clean; `cli/test/inline` passes; all 90 fast guards pass.
- **Review.** Lifecycle-sensitive, so a targeted review is selected. This harness has no subagent facility, so an independent review could not run; the diff was self-reviewed (the lock primitive on both sides, `start`'s fork/setsid/exec, and `supervise`'s lock/pid/streak) and is labelled a self-review, not an independent one.
- **Demo/example: not applicable** — internal local-cluster plumbing. **Language parity: no impact.**
