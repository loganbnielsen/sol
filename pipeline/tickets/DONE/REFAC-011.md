---
id: REFAC-011
branch: REFAC-011/readiness-probes
worktree: /home/lbendtly/Code/sun-REFAC-011-readiness-probes
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
---

Replace hardcoded sleep-and-check patterns with actual readiness probes

**Depends on:** None.

**Description:**

Three places in the CLI use fixed sleeps to wait for infrastructure that should instead wait for a real observable condition:

**1. `cmd_up.ml:107–108` — `check_port_forward_liveness`**
```ocaml
let check_port_forward_liveness ~name ~local_port =
  Unix.sleepf 0.2;   (* fixed 200 ms — no basis for this duration *)
  (* then checks PID liveness via kill -0 *)
```
This waits 200 ms and then verifies the wrapper process is alive, not that the port is actually listening. If the process is alive but `kubectl port-forward` hasn't bound the port yet (common on a loaded cluster), `check_port_forward_liveness` returns `true` even though connections would be refused. If the cluster is fast (< 200 ms), we waste time.

**2. `cmd_up.ml:484–486` — stale port-forward teardown**
```ocaml
(* Give the old process ~400 ms to release the port *)
Unix.sleepf 0.4
```
After `SIGTERM`-ing a stale port-forward, we sleep a fixed 400 ms. If the port is still held after that window, the new `kubectl port-forward` fails with EADDRINUSE.

**3. `cmd_dev.ml:213` — endpoint settle pause**
```ocaml
ignore (Sys.command "sleep 2");  (* brief pause for service endpoints to settle *)
```
After Helm installs infra, we sleep 2 full seconds before starting port-forwards regardless of whether the pods are actually ready.

**Remediation:**

1. **`cmd_up.ml` — replace `check_port_forward_liveness` with a port-probe loop:**
   ```ocaml
   let probe_port ~local_port ~timeout_s =
     let deadline = Unix.gettimeofday () +. timeout_s in
     let rec loop () =
       if Unix.gettimeofday () > deadline then false
       else
         let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
         let ok =
           (try Unix.connect sock
                  (Unix.ADDR_INET (Unix.inet_addr_loopback, local_port));
                Unix.close sock; true
            with Unix.Unix_error (Unix.ECONNREFUSED, _, _) ->
                Unix.close sock; false
               | _ ->
                Unix.close sock; false)
         in
         if ok then true
         else (Unix.sleepf 0.05; loop ())
     in
     loop ()
   ```
   Use `probe_port ~local_port ~timeout_s:3.0` instead of `sleepf 0.2` + PID check.

2. **`cmd_up.ml:484` — replace fixed 400 ms sleep with port-release probe:**
   After `SIGTERM`, poll `probe_port` with a short timeout. If the port does not release within 1 s, print a warning instead of silently proceeding.

3. **`cmd_dev.ml:213` — replace `sleep 2` with `kubectl wait`:**
   ```ocaml
   let wait_for_deployment_ready ~namespace ~name =
     let cmd = Printf.sprintf
       "kubectl wait --for=condition=Available=True deployment/%s -n %s --timeout=60s -q 2>/dev/null"
       (Filename.quote name) (Filename.quote namespace)
     in
     ignore (Sys.command cmd)
   in
   (* Call for each infra deployment that needs port-forwarding *)
   ```
   Or at minimum, replace the `sleep 2` with a `kubectl rollout status` call that actually blocks until the deployment is available.

**Acceptance criteria:**

- No call to `Unix.sleepf` with a magic constant as a "settle" or "release" delay.
- `sun up` successfully establishes port-forwards (test by running `curl http://localhost:<port>/healthz` after `sun up` completes).
- `sun dev up` port-forward setup does not regress.
- `dune build` passes.

## Review — automated checks passed
All readiness probe replacements implemented correctly: check_port_forward_liveness uses probe_port (TCP socket), 400ms SIGTERM sleep replaced with probe_port_released, sleep 2 in cmd_dev.ml replaced with kubectl wait; build passes; project/tickets/ unchanged
