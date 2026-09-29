# Code quality audit — 2026-09-28

Audited origin/main `6a7b1fb5` in an isolated worktree. Seven actionable findings: three high, four medium. These are findings, not implemented fixes.

| Severity | Ticket | Finding | Source |
|---|---|---|---|
| high | CODE_LAYER-023 | Drain both subprocess output streams through the existing argv runners | `internal/tooling/sol_process/lib/sol_process.ml:131-139 and cli/lib/base/sol_cli_process.ml:282-295` |
| high | BUG-067 | Wake idle workers when graceful stop is requested | `framework/ocaml/sol-worker/lib/worker.ml:100-125,209,306; framework/ocaml/kafka-eio-service/lib/kafka_service.ml consume paths` |
| high | BUG-068 | Enforce subprocess deadlines until the child exits | `cli/lib/base/sol_cli_process.ml:105-156,224-237` |
| medium | BUG-069 | Return a bad request for non-object charge JSON | `examples/pluto/app/payments/charge_svc/lib/handler.ml:11-38; platform/shared/templates/workspace/app/payments/charge_svc/lib/handler.ml:9-35` |
| medium | CODEX_STYLE_AUDIT-079 | Validate job timing configuration before entering the runtime | `framework/ocaml/sol-jobs/lib/sol_jobs.ml:32-48,225-243 and claim_q` |
| medium | CODE_LAYER-024 | Load a checked PR inventory once per pipeline operation | `internal/tooling/soldev/lib/soldev_merge.ml:36-59,587-659` |
| medium | BUG-070 | Preserve inbound trace context in the TypeScript order example | `examples/pluto/app/demo_ts/order_svc/src/index.ts:119-142; internal/specs/framework-conventions.md:34` |

## Evidence and practical impact

### CODE_LAYER-023: Drain both subprocess output streams through the existing argv runners

Both shell runners drain stdout to EOF before reading stderr. A child that fills stderr blocks before closing stdout, deadlocking the parent. Soldev PR creation and local service build commands use these paths.

Smallest remediation: Delegate shell execution to the existing argv runner with sh -c, preserving trimming, status and error contracts. Keep concurrency/capture logic in one implementation per runner.

### BUG-067: Wake idle workers when graceful stop is requested

Signal and external stop promises are sampled only from decoded-message handlers. An empty topic, malformed-only traffic, or stop during the final handler leaves consumption waiting for another message.

Smallest remediation: Propagate graceful stop through the shared service/consumer boundary so idle consumption wakes, while any active handler completes and acknowledges before closure. Update the pinned support package if that boundary requires it.

### BUG-068: Enforce subprocess deadlines until the child exits

The deadline is enforced only during pipe capture. After both output pipes close, blocking waitpid can exceed timeout_s indefinitely.

Smallest remediation: Keep the deadline active across both capture and child exit, then kill and reap a timed-out child through the shared runner.

### BUG-069: Return a bad request for non-object charge JSON

Yojson member raises Type_error for arrays, null and scalar roots. decode_charge_body catches syntax errors only, so valid non-object JSON escapes its Result contract and intended HTTP 400 path.

Smallest remediation: Validate the root object at decode_charge before reading members, returning an Error for every other JSON variant. Update example and scaffold together.

### CODEX_STYLE_AUDIT-079: Validate job timing configuration before entering the runtime

Only max_attempts is validated. Nonpositive lease_s permits immediate concurrent reclaim; negative max_delay_s yields negative backoff; invalid or nonfinite intervals/jitter reach sleeps, Random or SQL.

Smallest remediation: Extend the existing configuration boundary with finite/range checks for lease, polling interval, retry delays and jitter. Preserve supported zero retry delays and negative unlimited attempt counts.

### CODE_LAYER-024: Load a checked PR inventory once per pipeline operation

open_prs uses output_shell, discarding exit status and stderr. Authentication/network failure becomes an empty list, so merge reports success with no PRs. Listing also fetches the complete PR inventory for each READY ticket, multiplying remote calls and mixing snapshots.

Smallest remediation: Return a typed Result from a checked gh argv invocation and decode it at the adapter boundary. Resolve the inventory once per operation, then do local ticket lookups; propagate failed inventory retrieval rather than treating it as empty.

### BUG-070: Preserve inbound trace context in the TypeScript order example

The order route starts receive_order without extracting the incoming traceparent. Kafka propagation then forwards a newly rooted trace, severing caller-to-service-to-worker continuity. Provider registration alone does not supply HTTP instrumentation.

Smallest remediation: Extract the incoming carrier using the existing OpenTelemetry propagation API and pass the resulting context to span creation. Keep the existing Kafka header propagation.

## Executed checks

- `opam exec -- dune build internal/tooling/soldev/bin/main.exe internal/tooling/style_audit/main.exe` passed.
- `opam exec -- dune exec internal/tooling/style_audit/main.exe -- --json cli framework internal/tooling examples` passed with 43 parameter-sprawl candidates and no parameter-family candidates. These counts are advisory, not findings.
- A standalone harness compiled the unchanged Sol_process module and ran `head -c 262144 /dev/zero >&2`: argv returned `exit=0 stderr_bytes=262144`; shell did not complete under `timeout 3s` (exit 124). The argv path is the positive control.
- The unchanged CLI runner under an OCaml harness, with timeout_s=0.05: `sleep 0.5` returned Timeout in 0.051 seconds; `exec 1>&- 2>&-; sleep 0.5` returned Ok in 0.503 seconds. Its argv path drained a 1 MiB stderr child successfully, while shell stalled beyond a one-second harness bound.
- The real soldev executable with a temporary gh stub emitting `audit-authentication-failed` to stderr and exiting 1 returned exit 0, stdout `No open PRs to merge.`, empty stderr. A successful gh stub returning `[]` produced the same output/status. This reproduces error/empty conflation without contacting GitHub or merging anything.
- Installed Yojson member check: `{}` returned normally (positive control); `[]`, `null`, `42` each raised Type_error. Source tracing confirms charge decoding does not catch that exception.

Worker stop, job configuration and TypeScript trace findings are source-traced, not live reproduced. No full integration or cloud qualification run was performed for this evidence-only audit.

## Coverage

Manual representative folder walks included framework/ocaml (service/auth/peer/routes, worker/health, jobs, runtime signals, functions, observability, Kafka service/schema/retry), CLI base/kube/workspace/cloud/deploy/local and command controllers, OCaml and TypeScript Pluto examples, workspace/primitive scaffold templates, representative tests, internal/tooling (process, ticket parser, merge/list/check, cleanup, parameter checker), and representative internal/ci provider/readiness/storage/workflow guards. Interfaces, constructors, parsers/renderers and callers/tests were read together where relevant. This is a broad sample, not a line-by-line review of every file.

External support packages were followed where necessary to establish worker stop semantics; they were not independently audited. TypeScript implementation packages live in extracted repositories and were not audited. Terraform/cloud infrastructure and internal/qualification live-run records were not exhaustively audited; this is a code-quality review, not production qualification.

## Retained candidates and existing work

- Independent labeled lifecycle controls, compact Result pipelines, focused test defaults and existing constructors were retained. Long signatures alone establish no defect.
- Small setting-reader duplication avoids an unnecessary package dependency. Do not add a shared abstraction for these few lines.
- CODEX_STYLE_AUDIT-078 already owns sol open observability grouping; REFAC-155 owns consumer hook grouping. No duplicate tickets were filed.
- BUG-038 and REFAC-141 already describe merge-finish concerns. FEAT-097 owns the TypeScript Kafka security gap. Those were excluded from new findings.
- Six-digit random charge IDs remain collision-prone (roughly 50% collision probability by 1,177 generated IDs). FRIC-026 explicitly retained that simplification after fixing deterministic seeding. It is a residual reference-app limitation, not included in the seven new tickets.
- Option/Result nesting, collection grouping, phase pipelines and effect boundaries were inspected contextually. The actionable normalization findings are job validation and charge-root validation; the inventory finding moves decoding/error classification to the adapter and makes a stable outcome travel to controllers. No generic phase framework, dependencies bag or extra architecture layer is recommended.

Deduplication used `rg -n` across BACKLOG/READY tickets for stop/idle, lease/backoff, timeout/pipe, decoder/Type_error, run_shell/deadlock, inventory/gh failure, and inbound trace terms, followed by reading relevant DONE records and open candidates. Positive controls included existing FEAT-102 lifecycle work, BUG-050 lease fencing, REFAC-113 subprocess design and FEAT-097 security.

Recommended path: `command -> validated request -> operation -> typed outcome -> command rendering`, with protocol/subprocess details kept in their existing adapters. Repair the shared boundaries; avoid broad rewrites.

## Reproduce the CLI process findings

Run from the audited checkout (the process module is loaded unchanged; only its terminal reporter is stubbed):

```sh
opam exec -- ocaml -I +unix unix.cma <<'EOF'
module Sol_cli_report = struct
  let app fmt = Printf.ksprintf (fun _ -> ()) fmt
end;;
#mod_use "cli/lib/base/sol_cli_process.ml";;
let _ = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Exit));;
let probe label runner =
  ignore (Unix.alarm 1);
  (try
     let r = runner "head -c 262144 /dev/zero >&2" in
     Printf.printf "%s: completed=%b\n%!" label (Result.is_ok r)
   with Exit -> Printf.printf "%s: exceeded 1s\n%!" label);
  ignore (Unix.alarm 0);;
probe "argv control" (fun s -> Sol_cli_process.run (Sol_cli_process.cmd ["sh"; "-c"; s]));;
probe "shell" Sol_cli_process.run_shell;;
let timeout_probe script =
  let start = Unix.gettimeofday () in
  let r = Sol_cli_process.run (Sol_cli_process.cmd ~timeout_s:0.05 ["sh"; "-c"; script]) in
  Printf.printf "%.3fs %s\n%!" (Unix.gettimeofday () -. start)
    (match r with Ok _ -> "Ok" | Error (Sol_cli_process.Timeout _) -> "Timeout" | Error _ -> "other error");;
timeout_probe "sleep 0.5";;
timeout_probe "exec 1>&- 2>&-; sleep 0.5";;
EOF
```

## Filing validation

`opam exec -- dune exec internal/tooling/soldev/bin/main.exe -- pipeline validate` reads all 823 tickets successfully after this filing. `git diff --check` passes. Canonical checkout status is empty. No source files are changed.
