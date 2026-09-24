# FND-0042 — The process-global signal handler is modeled as per-run: last install wins, and the handler outlives its pipe

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `BUG-047`
- **Evidence class:** `STATIC`

## What is established

`Sol_runtime.install_signal_handler ~sw resolver`
(`framework/ocaml/sol-runtime/lib/sol_runtime.ml:9-36`) calls `Sys.set_signal` for
SIGTERM and SIGINT (process-global state) with a closure over a fresh pipe's write fd.
It then forks a daemon that closes **both** fds when its switch ends or after the first
signal. The handler is never restored.

Every primitive calls it inside its own `run`: `sol-svc` (`service.ml:283`),
`sol-worker` (`worker.ml:130`), `sol-fn` (`fn.ml:100, 127`), `sol-jobs`
(`sol_jobs.ml:162`). Two consequences:

1. **Last install wins.** In a process hosting more than one primitive, only the last
   `run` to install is resolved on SIGTERM. The others never see it and are killed at
   the grace deadline instead of draining. The repo's own local demo does this
   (`internal/fixtures/local-demo/bin/demo.ml` runs svc, worker and jobs in one process),
   and `sol-jobs.md` describes jobs as hosted in a `-worker` binary.
2. **The handler outlives its fd.** After the daemon closes the pipe (switch ended, or
   first signal handled), the installed handler still writes one byte to the old fd
   number, and the kernel may have reused that number for a socket or file. The
   `try … with _ -> ()` hides it. A second SIGINT or SIGTERM is also swallowed, so a
   second Ctrl-C does not kill a process stuck in shutdown.

## Impact

Low. Kubernetes sends one SIGTERM to a single-primitive process, which is the golden
path. It becomes real for co-hosted primitives and for local development.

## Remedy shape

Install one handler per process (lazily, once) that resolves every registered stop
promise, and have `run` register and unregister its promise rather than own the signal.
Restore the default disposition (or re-raise) after the first signal, so a second one
terminates.

## Related

REFAC-081 (the extraction into `Sol_runtime`); FND-0041.
