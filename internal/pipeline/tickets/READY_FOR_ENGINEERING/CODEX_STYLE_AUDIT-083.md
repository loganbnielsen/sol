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
