---
id: AUDIT-043
type: audit-finding
severity: high
source: codebase review 2026-06-13
branch: AUDIT-043/cli-command-runner
worktree: /home/lbendtly/Code/sun-AUDIT-043-cli-command-runner
---

Centralize external process execution; CLI modules hand-roll shell commands, temp files, process supervision, and output capture

**Depends on:** None.

**Description:** External command execution is scattered across the CLI with repeated `Sys.command`, shell redirection, temp-file capture, and ad hoc process management:

- `cli/sun/bin/cmd_up.ml` defines `run_cmd`, `run_cmd_to_string`, `git_sha`, `current_kube_context`, port-forward wrapper scripts, Docker build/push execution, rsync context creation, `kubectl apply`, `kubectl rollout status`, and ConfigMap state operations.
- `cli/sun/bin/cmd_dev.ml` separately defines `run_cmd`, `cmd_ok`, tool checks, Helm command assembly, port-forward wrapper scripts, `sleep`, and `Unix.create_process_env` supervision for `sun dev run`.
- `cli/sun/bin/cmd_deploy.ml`, `cmd_cloud.ml`, `cmd_status.ml`, `cmd_logs.ml`, `cmd_migrate.ml`, `cmd_rollback.ml`, `cli/sun/lib/sun_cli_secret.ml`, `cli/sun/lib/sun_cli_manifest.ml`, and `tools/sundev/bin/cmd_pipeline.ml` all construct and run shell commands directly.

This makes command behavior hard to audit. Some call sites discard stderr, some capture via temp files, some print the full command, some suppress output, and several rely on shell features (`>`, `2>/dev/null`, `&&`, background `&`, wrapper scripts) rather than an explicit argv API.

**Impact:** The same classes of bug can recur in multiple places: quoted strings can still pass through a shell, stderr can be lost on failure, temporary files can be leaked on exceptions, and timeout/retry/output formatting behavior is inconsistent. It also makes tests harder because there is no single seam for injecting fake `kubectl`, `helm`, `docker`, `git`, or `terraform` behavior.

**Remediation:**

1. Add a shared process module in `cli/sun/lib`, e.g. `Sun_cli_process`, with APIs for:
   - `run : ?echo:bool -> ?stdin:string -> string -> string list -> result`;
   - `capture : string -> string list -> (string, error) result`;
   - `check_tool : string -> install_url:string -> unit`;
   - structured result data including exit status, stdout, stderr, and rendered command.
2. Use `Unix.create_process`/`Unix.create_process_env` with argv arrays for normal commands instead of `Sys.command` shell strings. Keep an explicit `run_shell` escape hatch only where shell behavior is truly required, and document those call sites.
3. Migrate the duplicated helpers in `cmd_up.ml`, `cmd_dev.ml`, `cmd_deploy.ml`, `cmd_cloud.ml`, `cmd_status.ml`, `cmd_logs.ml`, `cmd_migrate.ml`, `cmd_rollback.ml`, `sun_cli_secret.ml`, and `sun_cli_manifest.ml` incrementally.
4. Add tests for command rendering, stdout/stderr capture, non-zero exit reporting, and fake-command injection for deploy/status/logs paths.

**Acceptance criteria:**

- New CLI code no longer calls `Sys.command` directly except through the shared process abstraction.
- At least `cmd_up.ml` and `cmd_dev.ml` share one implementation for tool checks, command execution, and capture.
- Non-zero `kubectl`, `helm`, `docker`, and `git` failures surface stderr in user-facing errors.
- Tests can exercise deploy/status behavior without invoking real external tools.

## Review — returned for revision
- `cli/sun/bin/cmd_up.ml:431` — docker build failure uses run_cmd -> run_shell; stderr not captured or surfaced. AC requires docker failures surface stderr. Use Sun_cli_process.run and report r.stderr on r.exit_code <> 0.
- `cli/sun/bin/cmd_up.ml:434` — docker push failure uses run_cmd -> run_shell; stderr not captured. Same fix as docker build.
- `cli/sun/bin/cmd_up.ml:242` — wait_for_rollout calls run_shell for kubectl rollout status — no shell features used, stderr not captured. Non-zero exit raises Deploy_failed with a static string, not the kubectl error output.
- `cli/sun/bin/cmd_up.ml:81` — setsid ... & (shell: background execution) lacks (* shell: <reason> *) comment required by Sun_cli_process module contract.
- `cli/sun/bin/cmd_dev.ml:35` — ensure_state_dir calls run_shell for plain mkdir -p with no shell features; should use Sun_cli_process.exec "mkdir" ["-p"; state_dir] as cmd_up.ml line 13 correctly does.
- `cli/sun/bin/cmd_dev.ml:85` — kill via run_shell with 2>/dev/null redirection is legitimate shell use but lacks the required (* shell: <reason> *) annotation per module contract.

## Review — automated checks passed
All shell operators annotated, all non-shell commands use Sun_cli_process functions, no ticket changes, build succeeds
