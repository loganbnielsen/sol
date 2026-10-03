# Error-collapse audit — 2026-10-02

**Revision inspected:** `origin/main @ 1eace495` (audited in an isolated worktree).
**Scope:** places where an *error*, an *unknown/unobservable* state, or a *failed
observation* is collapsed into a weaker value or a successful/definite outcome —
with emphasis on deployment, authorization, rollback, status/diagnostics,
verification, infrastructure probes, and external-system interactions.
**Method:** search the tree for the named constructs (`try … with`, `Error _ ->`,
`Result.to_option`, `Option.value ~default`, `ignore (…)`, `_ -> false/None/[]/""`,
warning-and-continue, `|| true`/`2>/dev/null`, `except`), then read each candidate
at its boundary **and its tests** before classifying. A construct is not a defect
by itself: the test is whether the lost distinction changes behaviour or the
verdict a human or the evidence receives.

This is a **themed** audit, not a pass over `internal/pipeline/audits/AUDIT.md`.
It is scoped, not exhaustive: it does not claim to have enumerated every
failure-handling site in the repository. Evidence is `STATIC` (source + tests)
except where a mutation run is named.

## Finding IDs and ticket policy

Findings in this report use the local `EC-nn` id. `EC-01`…`EC-03` are **resolved
by this PR itself**, so they are not materialised as tickets — a resolved finding
is not actionable work. `EC-04`…`EC-06` are open and are materialised as
`AUDIT-084`…`AUDIT-086` in `READY_FOR_ENGINEERING/`. (A new ticket cannot be
created directly in `DONE/`; the pre-commit *ticket transition* guard requires
filings to land in `BACKLOG/`/`READY_FOR_ENGINEERING` first, which a
fix-with-ticket would need as a separate PR.)

## State vocabulary

| State | Meaning |
|---|---|
| known-negative | the answer is legitimately "no / absent / false" |
| known-positive | the answer is legitimately "yes / present / ok" |
| unobservable / unknown | the read did not complete; the answer is not known |
| unsupported | the provider/contract does not offer the capability |
| failure | the operation ran and failed |

The collapse this audit hunts is any of `unobservable → known-negative`,
`failure → known-negative/positive`, or `unsupported → failure/absence`.

## Ledger

Every candidate the audit investigated. `Defect` = a distinction whose loss
produces a false success, false absence, misleading diagnosis, unsafe
continuation, or loss of actionable failure information.

| # | Location | Construct | Lost distinction | Verdict | Disposition |
|---|---|---|---|---|---|
| EC-01 | `cli/lib/cloud/sol_cli_supervised.ml` `latest` | `read_file_opt` → `None` → `No_previous` | unreadable previous-operation pointer → known-negative "nothing ran" | **Defect** (fail-open: Terraform state guard proceeds) | **Fixed in this PR** (test + mutation) |
| EC-02 | `cli/bin/cmd_grants.ml:138` | `Error _ -> Ok []` on `terraform output` | failed grant-state read → known-negative "no established grants" | **Defect** (false completeness: stale grants never revoked, `apply` reports reconciled) | **Fixed in this PR** |
| EC-03 | `cli/lib/cloud/sol_cli_aws_cluster.ml:166` `successor_probe` | `Error _ -> []` | failed provisioner probe → empty probe set | **Defect** (loses the cause; reported as "no successor capability was probed") | **Fixed in this PR** |
| EC-04 | `cli/bin/cmd_target.ml:24,5` | `Error _ -> Not_configured`; `Error _ -> []` | config/destination failure → "names no kube_context" / "no targets found" | **Defect** (misleading diagnosis; drops the reserved-local refusal) | Ticket AUDIT-084 |
| EC-05 | `cli/lib/deploy/sol_cli_rollback.ml:437-442` `read_jsonpath` | `_ -> ""` | unreadable pointer → empty pointer | **Defect** (verdict fails closed, but reports "names `<none>`", a definite absence) | Ticket AUDIT-085 |
| EC-06 | `cli/lib/workspace/sol_cli_ci.ml:56` | `read_file_opt` `None` → overwrite | unreadable existing workflow → absent | **Defect** (bypasses the `--force` guard; silent clobber) | Ticket AUDIT-086 |
| — | `cli/lib/deploy/sol_cli_deploy_run.ml:32,44` `http_services` | `Error _ -> []` / `false` | read failure → "no service URL" | Intentional-ish; diagnostic-only, printed *after* success | No ticket — noted |
| — | `cli/lib/deploy/sol_cli_deploy_run.ml:274` `surplus_workloads` | `Error _ -> []` | read failure → "no surplus workloads" | Intentional-ish; note-only, workspace scope only | No ticket — noted |
| — | `cli/lib/deploy/sol_cli_deploy_run.ml:103` | `Ok [] \| Error _ -> Ok ()` | unreadable migrations dir → "no migrations" | Intentional for a dry run — the live path (`verify → Unavailable → Failed`) fails closed | No ticket — noted |
| — | `cli/lib/cloud/sol_cli_target_report.ml:89` `context_is_configured` | `Error _ -> true` | failed `kubectl get-contexts` → "context configured" | Intentional: do not provision a new environment on an unreadable probe; a bad context then fails at `kubectl` | No ticket — noted |
| — | `framework/ocaml/kafka-eio-service/lib/kafka_service_intf.ml:176` | `ignore (ack ())` in `ack_and_drop_decode_error` | failed ack → dropped | Intentional semantics; residual: an ack failure is not logged and the poison message repeats | No ticket — noted |
| — | `framework/ocaml/sol-outbox/lib/sol_outbox.ml:114,123` | `Error _ -> ()` | failed metrics query → no gauge update | Intentional: a metrics scrape must not fail the relay; no log | No ticket — noted |
| — | `framework/ocaml/sol-outbox/lib/sol_outbox.ml:80` | `Option.value ~default:0` | no row → 0 pending | N/A: `count(*)` always returns a row | — |
| — | `framework/ocaml/sol-svc/lib/auth_internal.ml:248` | `Error _ -> not_found` | JWKS refetch failure → "kid not found" (401) | **Intentional, test-pinned** (`test_unknown_kid_with_failed_refetch_is_401`); a cold-cache outage is already 500 | No ticket — noted |
| — | `framework/ocaml/sol-svc/lib/auth_internal.ml:52` | `Error _ -> None` | base64 decode failure → None | N/A: caller converts to `Unauthorized "cannot decode payload"` | — |
| — | `framework/ocaml/sol-svc/lib/auth_internal.ml:112-117` | `_ -> false` (`jwt_expired`) | missing/non-numeric `exp` → not expired | Intentional (dev-only path); the verified path treats absent `exp` as no expiry by contract | — |
| — | `framework/ocaml/sol-svc/lib/auth_internal.ml:64,297` | `_ -> []` (scope/claim) | malformed claim type → no scopes | Intentional, fail-closed: required-scope checks then reject | — |
| — | `framework/ocaml/sol-svc/lib/service.ml:169-189` | handler `try … with exn` → 500 | exception → 500 response | Intentional: logs the exception, keeps the server alive, never masks it as success | — |
| — | `framework/ocaml/sol-worker/lib/worker.ml:148-170` | ack result matched | — | **Clean**: fatal ack → error; non-fatal → logged redelivery | — |
| — | `framework/ocaml/kafka-eio-service/lib/kafka_service.ml:314` + intf | decode error policy | — | **Clean**: counter + structured log + DLQ; `Ack_and_drop` is explicit policy | — |
| — | `cli/lib/base/sol_cli_destroy_verification.ml:92-108` | `indeterminate` sweep probes excluded from `classify` unknowns | indeterminate residue probe → exit 0 | Intentional: `completion_message` and `residue_absence_established` surface it explicitly; `Retention_unknown` *is* in `unknowns` | — |
| — | `cli/lib/cloud/sol_cli_cloud_wiring.ml:474-477` | `Error _ -> ""` outputs | failed output read → empty outputs | **Clean**: `acceptable Unknown → Error Refused` (fails closed) | — |
| — | `cli/lib/kube/sol_cli_kubectl.ml:140-181` | `probe_result`/`presence_of_probe_result` | — | **Clean**: tri-state `Present/Absent/Uncheckable`, `Error` kept separate | — |
| — | `cli/lib/cloud/sol_cli_absence.ml` + aws/gcp adapters | `Absent/Present/Unobservable` | — | **Clean**, with one needle risk (below) | — |
| — | `cli/lib/cloud/sol_cli_absence.ml:51-55` + `sol_cli_aws_absence.ml:32-35` | `not_found` substring needles incl. `"no such"` | a non-absence error containing `"no such"` → Absent | Already tracked by CODE_LAYER-028 (the two adapters classify `no such` differently); not re-filed | See CODE_LAYER-028 |
| — | `cli/lib/deploy/sol_cli_authorization_reconcile.ml:114-131` | `Ok []` for a missing `established_grants` output | no-state → no grants | Intentional: a `{}`/absent output is legitimately empty; only the *run* failure (EC-02) was the collapse | — |
| — | `cli/lib/deploy/sol_cli_migration_gate.ml:32-38` | `warn` on operator RoleBinding failure | diagnostic-binding failure → warning | Intentional: diagnostics degrade, deploy correctness unaffected; message names the consequence | — |
| — | `cli/lib/deploy/sol_cli_deploy_run.ml:261` | `warn` on prune failure | prune failure → deploy success | Intentional: housekeeping only; deploy's own postcondition is the release record | — |
| — | `cli/lib/cloud/sol_cli_state_guard.ml:40-55` | `Warn`/`Acknowledge`/`Refuse` | — | **Clean** (tri-state verdict; constructive ops refuse unresolved) — and strengthened by the EC-01 fix | — |
| — | `internal/tooling/scripts/run_tests.sh:107` | `set +e` | — | **Clean**: exit code captured via `PIPESTATUS[0]` and propagated to the summary/exit | — |
| — | `internal/ci/*.sh` | `\|\| true`, `2>/dev/null` | — | **Clean** in sampled guards: "no match" stays empty and the guard then fails on emptiness (consistent with the 2026-09-21 fail-open audit) | — |
| — | `internal/ci/*.py` | `except` | — | No broad/bare `except` found; the one parse failure returns an explicit error string | — |
| — | `examples/pluto/app/demo_ts/**` | `catch`, `??` | — | No naked swallow; `db.ts:66` discards ROLLBACK failure in an error path (standard pool recovery), push failures are logged, `/readyz` `?? true` matches the OCaml `ready = true` default | — |
| — | `internal/tooling/sol_process/lib/sol_process.ml:158-182` | shell family discards status/stderr | — | Already tracked by CODE_LAYER-030 | See CODE_LAYER-030 |

## EC-01 — an unreadable previous-operation pointer read as "no previous operation"

`Sol_cli_supervised.latest` distinguished only "pointer absent" from "pointer
present" by observing that `read_file (latest_file ~key)` returned `None` — but
`read_file = Sol_cli_fs.read_file_opt`, which returns `None` for **every** read
error, not only `ENOENT`. A permission or I/O error on the pointer therefore
produced `No_previous`, and `Sol_cli_state_guard.verdict` maps
`No_previous → Proceed`: the Terraform state guard exists precisely to refuse
when a previous operation may have left provider changes unrecorded, and this
path let it proceed. The fix keeps the existing `Unresolved` third state and
uses it when the pointer exists but cannot be read:

```ocaml
| None when Sys.file_exists (latest_file ~key) -> Unresolved { … }
| None -> No_previous
```

A constructive `sol cloud apply`/`destroy` now refuses (and a non-constructive
one warns) instead of silently proceeding.

**Evidence.** New test `test_unreadable_pointer_is_unresolved` in
`cli/test/test_supervised.ml`: it creates `operations/<key>/latest` as a
directory (readable as a path, unreadable as a file) and asserts `latest` is
`Unresolved`. **Mutation run:** with the pre-fix `latest` restored the test
fails on exactly that assertion (`Expected true, Actual false`); with the fix it
passes, and the full `supervised` suite is 9/9.

## EC-02 — a failed authorization-state read planned as "no stale grants"

`sol grants plan|apply` (`cli/bin/cmd_grants.ml`) reads the authorization root's
outputs and, on any failure, substituted `Ok []` for the established-grant set.
`Sol_cli_authorization.compute` derives `stale = current \ desired`, so an empty
`current` yields **no removals**: a grant that is established in the root but no
longer declared would not be revoked, and `apply` printed "Workload
authorization is reconciled." — a reconciliation it did not perform.
`terraform output -json` against an initialized root with no state exits 0 with
`{}`, which `current_of_output_json` already maps to `Ok []`; the collapsed
branch was therefore a genuine run failure, not the empty-state case. The fix
propagates the failure through `refuse` with an explicit message.

## EC-03 — the successor-authority probe discarded why it could not run

`successor_probe` (`cli/lib/cloud/sol_cli_aws_cluster.ml`) reduced a failed
`provisioner_kubeconfig` to `[]`, and `successor_authority []` reports the
generic "no successor capability was probed, so the successor's authority is not
established". The refusal was correct (fail-closed) but the actionable cause —
credentials that could not assume the provisioner role — was dropped.
`successor_probe` now returns the `result` and the deescalation branch reports
the underlying reason.

## Verification performed

- `dune build cli/bin/main.exe` passes.
- `dune build @ci-unit` (inline CLI tests, `supervised`, `service`): all pass.
  The two `Test_scaffold` compile cases fail on a cold first run in a fresh
  worktree and pass once the build tree is warm — they also fail identically on
  the clean `origin/main` checkout in this worktree, so they are pre-existing and
  environmental (BUG-017 stale-build recovery), not caused by this change.
- `internal/ci/check_ocamlformat.sh --staged` passes on the changed files.
- `internal/tooling/soldev ... pipeline validate`: 963 tickets read, all
  readable.
- `internal/ci/run_fast_checks.sh`: build, lifecycle, context-bound guards and
  all verification classes pass; the transient `@ci-unit` first-run failure is
  the environmental scaffold case above and passes on the warm rerun.

## What is not established

- Evidence is `STATIC` (source + tests) except the EC-01 mutation run. No live
  cloud or cluster mutation was performed.
- Rows marked "noted" are deliberate or low-impact collapses left in place; they
  are recorded here so the audit closes with an explicit disposition rather than
  an open-ended cleanup program.
- The audit searched the constructs named in the brief across `cli/`,
  `framework/`, `internal/` tooling and guards, `platform/local/scripts/`, and
  the TypeScript demo. It did not read every one of the 364 OCaml files line by
  line; an absence of a row is not a guarantee.
