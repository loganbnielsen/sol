---
id: FRIC-006
type: dogfood-finding
severity: blocker
source: project/dogfood/RUN_2026-09-07.md
branch: fric-006/surface-subprocess-errors
worktree: ../sol-fric-006-surface-subprocess-errors
pr: https://github.com/loganbnielsen/sol/pull/140
---

**Depends on:** None.

`sol dev up` and `sol up` swallow subprocess stdout/stderr on failure, making every failure mode undiagnosable without re-running the raw command by hand.

**Description:** `Sol_cli_process.run` already captures a child process's `stdout`/`stderr` into its `result` record (`cli/sol/lib/sol_cli_process.mli`), but the call sites that use it on the CLI's critical path discard that output and print only a fixed, generic message on failure:

- `cmd_dev.ml:88` (cluster creation): `if rc <> 0 then (Printf.eprintf "error: cluster creation failed\n"; exit 1)` — the real `k3d` error (in this run's dogfood pass: `Bind for 0.0.0.0:5000 failed: port is already allocated`) is never printed.
- `cmd_up.ml:156` (docker build): `Error _ -> raise (Deploy_failed (Printf.sprintf "docker build failed: %s" spec.source_dir))` — the real `docker build`/dune compiler error is never printed.
- `cmd_up.ml:160` (docker push): same pattern.
- `cmd_up.ml:178` (rollout wait): `raise (Deploy_failed (Printf.sprintf "rollout failed: %s/%s" namespace k8s_name))` — no indication of *why* the rollout failed (crash-looping pod, image pull error, readiness probe failure, etc.); the user has to know to run `kubectl logs`/`kubectl describe pod` themselves.

**Impact:** In the 2026-09-07 dogfood run, this pattern turned two genuinely different, quickly-diagnosable failures (a port conflict during cluster creation; a schema-registry rejection during rollout — see FRIC-007) into ~50 minutes of manual investigation each, because `sol`'s own output gave zero indication of what had actually gone wrong. A first-time user hitting either of these has no path forward from `sol`'s own output alone — they'd have to already know to inspect `k3d`/`docker`/`kubectl` directly, which defeats the entire point of a CLI that's supposed to abstract those tools away.

**Remediation:** At each of the four call sites above, print the captured `result.stdout`/`result.stderr` (or the `Error` payload's message, for cases going through `Sol_cli_process.run_ok`) before or as part of the existing generic error message, rather than discarding it. For the rollout-wait case specifically, consider also running `kubectl get pods -n <namespace> -l app=<name>` and including pod status/restart count in the failure message, since "rollout failed" alone doesn't tell the user whether the problem is CrashLoopBackOff, ImagePullBackOff, or something else — the actual reason is usually visible in one `kubectl describe pod` call that `sol up` is already well-positioned to make on the user's behalf.
