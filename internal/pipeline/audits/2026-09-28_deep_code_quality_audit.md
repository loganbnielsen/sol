# Deeper code quality audit — 2026-09-28

Follow-up to PR #682, pinned to origin/main `2dfa5694`. Seven additional findings: three high and four medium. No runtime fixes were implemented. This is a deeper path audit, not an exhaustive claim about every source file.

| Severity | Ticket | Finding |
|---|---|---|
| high | BUG-071 | Preserve exclusive boundary ownership throughout deploy and rollback |
| high | BUG-072 | Preserve scheduled execution policies in release identity and rollback |
| medium | BUG-073 | Accept request bodies exactly at the configured maximum |
| high | BUG-074 | Serialize process signal registration and restoration across domains |
| medium | BUG-075 | Keep build-context copying from dereferencing workspace symlinks |
| medium | BUG-076 | Resolve npm workspace membership from relative paths |
| medium | CODE_LAYER-025 | Keep subprocess ownership exception-safe when capture is interrupted |

## BUG-071: Preserve exclusive boundary ownership throughout deploy and rollback

Source: `cli/bin/cmd_rollback.ml:101; cli/lib/deploy/sol_cli_boundary_lease.ml:30,78-109; cli/lib/deploy/sol_cli_deploy_run.ml:268-291`.

Rollback discards its held lease and never heartbeats or verifies ownership. At 301 seconds its lease is reclaimable while it can still apply workloads, prune and move the release pointer. Deploy renews before each workload but does not maintain ownership through a long last apply and recording. Competing operations can therefore mutate the same boundary.

Smallest remediation: Maintain the existing lease through long-running operations and verify ownership before each subsequent mutation and pointer/record commit. Thread held ownership through rollback rather than discarding it. Raising the TTL alone is insufficient. Document the fencing/stop behavior for an operation already in progress when ownership is lost.

## BUG-072: Preserve scheduled execution policies in release identity and rollback

Source: `cli/lib/deploy/sol_cli_deployment_plan.ml:191; cli/lib/base/sol_cli_release_id.ml:1-22,101; cli/lib/deploy/sol_cli_release.ml; cli/lib/deploy/sol_cli_rollback.ml:156-157`.

Release workload projection, hashing and stored JSON omit scheduled_concurrency and backoff_limit. Rollback reconstructs every function as Allow with backoff_limit 3. A Forbid/0 function can return as an overlapping retrying job; changing only these settings also leaves the release ID unchanged.

Smallest remediation: Carry both scheduled execution fields through the existing release projection, canonical identity encoding, JSON validation/storage and reconstruction. Update the encoding version coherently; no compatibility shim is required in this pre-alpha repository.

## BUG-073: Accept request bodies exactly at the configured maximum

Source: `framework/ocaml/sol-svc/lib/service.ml:40-56`.

Passing max_body_bytes as Eio Buf_read max_size makes take_all reject a body exactly equal to the maximum: EOF detection requests one additional byte. The public contract rejects requests exceeding the limit, not requests equal to it.

Smallest remediation: Use a bounded read that can distinguish exactly N bytes from N+1 and explicitly enforce the public length limit. Keep memory bounded and handle numeric edge cases instead of blindly overflowing N+1.

## BUG-074: Serialize process signal registration and restoration across domains

Source: `framework/ocaml/sol-runtime/lib/sol_runtime.ml:25-39`.

The atomic registration list is updated separately from checking emptiness, installing/restoring signal handlers and saving the mutable previous dispositions. Concurrent domains can overwrite the original disposition with Sol's own handler, leaving it installed after all registrations close. With an empty listener list the leaked handler swallows the first SIGTERM.

Smallest remediation: Serialize registration/removal and the associated saved-disposition bookkeeping with one shared synchronization boundary. Keep the signal callback lock-free. Preserve the existing first-signal graceful stop and second-signal termination behavior.

## BUG-075: Keep build-context copying from dereferencing workspace symlinks

Source: `cli/lib/base/sol_cli_fs.ml:127-146; cli/lib/deploy/sol_cli_up_execution.ml:63-74`.

copy_tree uses Unix.stat and follows workspace symlinks. A link to a file outside the workspace becomes a regular file containing that external data in the Docker context; directory links recurse outside the workspace, including ancestor cycles. Docker sees the already-dereferenced copy, so this can expose external data to COPY . and break local builds.

Smallest remediation: Inspect entries with lstat and preserve link identity without reading external targets, or reject links with an explicit diagnostic if that is the supported policy. Do not introduce a new copying framework. Preserve current regular-file permissions and exclusions.

## BUG-076: Resolve npm workspace membership from relative paths

Source: `cli/lib/local/sol_cli_local_run.ml:72-97`.

declares treats any workspace entry containing * as matching every service and otherwise compares package name or final directory basename. An ancestor tools/* declaration wrongly captures app/api/api_svc, while the valid exact entry app/api/api_svc is rejected. Generated npm build commands then select the wrong project root.

Smallest remediation: Resolve membership using the unit directory relative to each candidate npm root and npm's supported workspace semantics. Reuse an installed/native resolver where practical; do not make arbitrary glob strings mean universal membership. Keep standalone packages independently buildable.

## CODE_LAYER-025: Keep subprocess ownership exception-safe when capture is interrupted

Source: `cli/lib/base/sol_cli_process.ml:133,224-237; internal/tooling/sol_process/lib/sol_process.ml:64,118-123`.

Both capture loops call Unix.select without EINTR handling, and both runners close read descriptors/reap the child only after capture returns normally. An innocuous handled signal raises Interrupted system call from run, leaks two descriptors and leaves the child unreaped. This violates the runner result boundary and leaks ownership during cancellation/errors.

Smallest remediation: Retry EINTR while retaining the deadline and protect descriptors/child ownership through exceptional exits. Preserve cancellation semantics: cleanup before propagating cancellation, rather than silently converting it to success. Repair the existing runners instead of adding per-caller recovery.

## Executed evidence

- **Lease:** the production decision function refuses a rollback lease at 299 seconds and permits takeover at 301 seconds for TTL=300. Tracing the actual rollback callback confirms no heartbeat or ownership check. This is a pure-decision reproduction plus source trace; no live concurrent cluster mutation was performed.
- **CronJob:** source-traced complete spec -> release projection -> hash -> JSON -> rollback -> render flow. Stored workload type lacks both policy fields; reconstruction hardcodes Allow/3. Existing function rollback fixture also uses Allow/3. No live rollback reproduction was performed.
- **Body limit:** the exact Eio read used by service with max_size=50 accepted 49 bytes, rejected 50 and rejected 51. N-1 is the positive control. This exercises the dependency behavior, not a live HTTP server.
- **Signals:** the unchanged Sol_runtime module compiled in a temporary directory with installed Eio dependencies. Single-domain control restored default SIGTERM. A barrier-synchronized two-domain registration/release loop left Sol's SIGTERM handler installed after both switches closed at rounds 5, 1 and 2; author repeat reproduced it at round 3. The test inspects disposition; it does not signal the operator's process.
- **Copy:** loading unchanged Sol_cli_fs with minimal reporting/map_list shims and a temporary src/linked-secret -> ../outside-secret fixture returned `copy success=true; destination is regular=true; contents=outside content`. The regular target is the data positive control. Fixture cleanup used remove_tree.
- **npm:** actual declares function accepts api_svc (positive control), incorrectly accepts unrelated tools/*, and rejects the valid exact path app/api/api_svc. A temporary actual npm fixture with tools/* at the ancestor made generated `npm run build --workspace api-svc` exit 1 (`No workspaces found`); direct `npm run build` in the standalone unit exits 0 and prints 1.
- **Interrupted capture:** loading unchanged Sol_cli_process and installing a no-op SIGALRM handler during `sleep 0.2` raised `select: Interrupted system call`, increased /proc/self/fd by two, and left a child collectable by later waitpid. The probe reaped its child after measuring. A separate normal stop probe also found stop does not wait for final termination/reaping; that is retained as a related lifecycle limitation rather than another ticket.

## Coverage and deduplication

Manually followed service body/auth/exception handling, framework signal lifecycle, fn cron/Lambda cancellation, worker/jobs cleanup, release identity/storage/render/reconstruction, rollback transaction/pruning/pointer flow, deploy lease callbacks, migration gates/Jobs, filesystem copying, npm discovery, local process/port-forward launch/cleanup, and both subprocess runner implementations with representative tests and interfaces.

The first seven findings remain separate. New interruption cleanup is distinct from shell pipe deadlock and closed-pipe deadlines; it needs signal/exception regression coverage. Multi-domain handler restoration is distinct from idle-worker stop. Release policy loss is distinct from the existing encoding-version diagnostic ticket. Filesystem link dereferencing is distinct from BUG-036 context placement.

Used `rg -n` across BACKLOG/READY tickets for signal races/multi-domain restoration, body/exact limits, heartbeat/rollback ownership, CronJob rollback policies, symlinks, npm workspace discovery and EINTR; then read relevant existing records/tests. Positive controls include BUG-067/068, CODE_LAYER-023/024, BUG-036, AUDIT-077, existing single-runtime signal tests, body-over-limit tests, boundary lease stale/live tests, and filesystem copy tests. No matching pending work owns these additional concrete defects.

No broad architecture rewrite, count-only argument refactor, generic state-machine framework or new dependency is recommended. The retained path remains command -> validated operation -> typed outcome -> command output; runtime resources should have explicit owners and complete cleanup.

Not inspected exhaustively: Terraform/provider infrastructure, live qualification records, every scaffold/example, every CLI decoder, or extracted TypeScript/support repositories. No expensive infrastructure was provisioned. Full integration/cloud qualification was not run for an evidence-only filing. This pass raises total filed findings to fourteen; it does not certify absence of further defects.

## Build and filing checks

`opam exec -- dune build cli/bin/main.exe internal/tooling/soldev/bin/main.exe` passed. Focused reproductions follow the e2e skill's debugging workflow. `opam exec -- dune exec internal/tooling/soldev/bin/main.exe -- pipeline validate` reads all 830 tickets. `git diff --check` passes. All six documented reproduction commands were executed from this tree; signal-free capture leaked zero descriptors and the concurrent signal repeat exposed the race at round 1. Canonical checkout status is empty.

## Runnable reproduction commands

Run these from the audited checkout. They use throwaway files/processes and do not mutate cloud infrastructure. Helpers are loaded unchanged; shims cover only reporting/formatting dependencies.

### Interrupted capture

```sh
opam exec -- ocaml -noinit -noprompt -I +unix unix.cma <<'EOF'
module Sol_cli_report = struct let app fmt = Printf.ksprintf (fun _ -> ()) fmt end;;
#mod_use "cli/lib/base/sol_cli_process.ml";;
let count () = Array.length (Sys.readdir "/proc/self/fd");;
let old = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> ()));;
let before = count ();;
ignore (Sol_cli_process.run (Sol_cli_process.cmd ["sleep"; "0.01"]));;
Printf.printf "signal-free fd_delta=%d\n%!" (count () - before);;
ignore (Unix.setitimer Unix.ITIMER_REAL {Unix.it_interval=0.;it_value=0.05});;
let outcome = try ignore (Sol_cli_process.run (Sol_cli_process.cmd ["sleep"; "0.2"])); "completed" with Unix.Unix_error (e,f,_) -> f ^ ": " ^ Unix.error_message e;;
ignore (Unix.setitimer Unix.ITIMER_REAL {Unix.it_interval=0.;it_value=0.});;
Printf.printf "%s fd_delta=%d\n%!" outcome (count () - before);;
Unix.sleepf 0.25;;
let pid,_ = Unix.waitpid [Unix.WNOHANG] (-1);;
Printf.printf "unreaped child=%d\n%!" pid;;
Sys.set_signal Sys.sigalrm old;;
EOF
```

Observed interrupted run: `select: Interrupted system call fd_delta=2`, followed by a nonzero child pid.

### Lease decision

```sh
{
cat <<'EOF'
module Sol_cli_kubernetes_name = struct let sanitize_name s = s end;;
module Sol_cli_deployment = struct let rfc3339_utc = string_of_float end;;
EOF
sed -n '1,109p' cli/lib/deploy/sol_cli_boundary_lease.ml
cat <<'EOF'
let lease = create ~boundary:"demo" ~holder:Rollback ~run_id:"active" ~now:0.;;
let display = function Proceed -> "Proceed" | Refuse _ -> "Refuse" | Request_abort _ -> "Request_abort";;
Printf.printf "299s: %s\n" (display (deploy_decision ~now:299. ~ttl:default_ttl_s (Some lease)));;
Printf.printf "301s: %s\n" (display (deploy_decision ~now:301. ~ttl:default_ttl_s (Some lease)));;
EOF
} | opam exec -- ocaml -noinit
```

Observed: `299s: Refuse`, `301s: Proceed`. Source trace establishes that rollback does not renew this timestamp.

### Symlink copying

```sh
opam exec -- ocaml -noinit -noprompt -I +unix unix.cma <<'EOF'
module Sol_cli_report = struct let warn fmt = Printf.ksprintf (fun _ -> ()) fmt end;;
module Sol_cli_result = struct
  let rec map_list f = function
    | [] -> Ok []
    | x::xs -> Result.bind (f x) (fun y -> Result.map (fun ys -> y::ys) (map_list f xs))
end;;
#mod_use "cli/lib/base/sol_cli_fs.ml";;
let root = Filename.temp_file "sol-deep-fs" "";;
Sys.remove root;;
Unix.mkdir root 0o700;;
let src = Filename.concat root "src";;
Unix.mkdir src 0o700;;
let outside = Filename.concat root "outside-secret";;
ignore (Sol_cli_fs.write_file outside "outside content");;
Unix.symlink "../outside-secret" (Filename.concat src "linked-secret");;
let dst = Filename.concat root "dst";;
let result = Sol_cli_fs.copy_tree ~exclude:[] ~src ~dst;;
let copied = Filename.concat dst "linked-secret";;
Printf.printf "copy success=%b; destination is regular=%b; contents=%s\n%!" (Result.is_ok result) ((Unix.lstat copied).Unix.st_kind=Unix.S_REG) (In_channel.with_open_bin copied In_channel.input_all);;
ignore (Sol_cli_fs.remove_tree root);;
EOF
```

Observed: `copy success=true; destination is regular=true; contents=outside content`.

### Request body boundary

```sh
audit_tmp=$(mktemp -d)
cat > "$audit_tmp/probe.ml" <<'EOF'
let () =
  List.iter
    (fun size ->
      let body = Eio.Flow.string_source (String.make size 'x') in
      let result =
        try
          let reader = Eio.Buf_read.of_flow body ~max_size:50 in
          Printf.sprintf "accepted %d" (String.length (Eio.Buf_read.take_all reader))
        with Eio.Buf_read.Buffer_limit_exceeded -> "rejected: Buffer_limit_exceeded"
      in
      Printf.printf "body=%d limit=50 -> %s\n" size result)
    [49; 50; 51]
EOF
opam exec -- ocamlfind ocamlopt -linkpkg -package eio -o "$audit_tmp/probe" "$audit_tmp/probe.ml"
"$audit_tmp/probe"
rm -r "$audit_tmp"
```

Observed: 49 accepted; 50 and 51 rejected at limit 50.

### Concurrent signal restoration

```sh
audit_tmp=$(mktemp -d)
cp framework/ocaml/sol-runtime/lib/sol_runtime.ml "$audit_tmp/sol_runtime.ml"
cat > "$audit_tmp/probe.ml" <<'EOF'
let () =
  let failed = ref false in
  for round = 1 to 2000 do
    if not !failed then (
      let entered = Atomic.make 0 in
      let registration_done = Atomic.make 0 in
      let work () =
        Eio_main.run (fun _ ->
          Eio.Switch.run (fun sw ->
            ignore (Atomic.fetch_and_add entered 1);
            while Atomic.get entered < 2 do Domain.cpu_relax () done;
            let _, resolver = Eio.Promise.create () in
            Sol_runtime.install_signal_handler ~sw resolver;
            ignore (Atomic.fetch_and_add registration_done 1);
            while Atomic.get registration_done < 2 do Domain.cpu_relax () done))
      in
      let domain = Domain.spawn work in
      work ();
      Domain.join domain;
      match Sys.signal Sys.sigterm Sys.Signal_default with
      | Sys.Signal_default -> ()
      | _ -> failed := true; Printf.printf "round=%d: SIGTERM handler leaked after both switches closed\n%!" round)
  done;
  if not !failed then Printf.printf "2000 rounds restored default disposition\n"
EOF
opam exec -- ocamlfind ocamlopt -linkpkg -package eio.unix,eio_main -I "$audit_tmp" -o "$audit_tmp/probe" "$audit_tmp/sol_runtime.ml" "$audit_tmp/probe.ml"
"$audit_tmp/probe"
rm -r "$audit_tmp"
```

Observed author repeat: `round=3: SIGTERM handler leaked after both switches closed`. This is scheduling-sensitive; a passing run does not disprove the race. Single-domain control restored the default disposition.

### npm build root

```sh
python3 - <<'PYTHON'
import json, pathlib, subprocess, tempfile
with tempfile.TemporaryDirectory(prefix="sol-npm-audit-") as tmp:
    root = pathlib.Path(tmp)
    unit = root / "app/api/api_svc"
    unit.mkdir(parents=True)
    (root / "package.json").write_text(json.dumps({"name":"root","private":True,"workspaces":["tools/*"]}))
    (unit / "package.json").write_text(json.dumps({"name":"api-svc","scripts":{"build":"node -p 1"}}))
    for cwd, command in [(root,["npm","run","build","--workspace","api-svc"]),(unit,["npm","run","build"])]:
        result = subprocess.run(command,cwd=cwd,capture_output=True,text=True)
        print(command,"exit",result.returncode,result.stdout,result.stderr)
PYTHON
```

Observed: ancestor command exits 1 with `No workspaces found`; standalone control exits 0 and prints 1. The declares function shown at local_run.ml:72-76 chooses the incorrect ancestor because tools/* contains *.
