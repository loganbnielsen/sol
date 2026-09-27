---
id: REFAC-132
type: refactor
severity: medium
title: One JSON decode boundary for tool output -- malformed input is an Error, never [], None or false
source: pattern audit of the REFAC-104..130 series (2026-09-26); REFAC-127 fixed this for rollout diagnosis only
premise: "test -f cli/lib/base/sol_cli_json.ml"
---

**Depends on:** None.

## The problem

REFAC-127 built a decode boundary (a `decode` that catches `Yojson.Json_error` only, a total `field` path lookup, `Ok []` only for an API-empty list), but it is private to `sol_cli_rollout_diagnosis.ml`. About twenty other modules decode Yojson by hand, and several repeat exactly the conflation 127 removed -- a read that failed reads as an answer about the cluster (FND-0024, DEC-038 §7):

- `cli/lib/local/sol_cli_loki.ml:73-87`: `try … U.to_list with _ -> []` -- a malformed Loki response is "no log lines".
- `cli/lib/deploy/sol_cli_release_store.ml:50-96`: a malformed `metadata` or `data` becomes `None` / `[]`.
- `cli/lib/cloud/sol_cli_cloud_lifecycle.ml:420-517`: readiness is read by splitting kubectl text output, and output it cannot parse is `false` ("not ready") rather than "unreadable".
- `cli/lib/cloud/sol_cli_terraform_outputs.ml:20-31`: an output of an unexpected shape is dropped (`| _ -> None`).

`rg -c 'Yojson' cli/lib --glob '*.ml'` (2026-09-26) lists 20+ files; `rg -c 'Util\.member' cli/lib` counts 32 raising accessors.

## Remediation

- Promote the REFAC-127 boundary to `Sol_cli_json` in `cli/lib/base`: `decode ~what : string -> (Yojson.Safe.t, string) result`, a total `field` path lookup, typed accessors returning `result` that name the path on a mismatch (`string_at`, `int_at`, `list_at`, `assoc_at`, and `_opt` forms where absence is a real answer).
- Move `sol_cli_rollout_diagnosis` onto it, then sweep every Yojson decoder in `cli/lib` and `cli/bin`. Where a readiness or presence check parses kubectl output, ask for `-o json` and decode it, rather than splitting text.
- Where absence is meaningful (Kubernetes' omitempty), the decoder says so in the type; where it is not, it is an `Error`.
- A test rule: no `Yojson.Safe.Util.member` / `to_list` / `to_string` outside `Sol_cli_json`, and no `with _ ->` around a JSON decode in `cli/`.

## Acceptance criteria

- For each converted decoder, a test: malformed JSON and missing structure are `Error`, the empty answer is `Ok []`/`Ok None` (positive control).
- `sol logs` reports a malformed Loki response as an error, not as "no logs" (test).
- The test rule runs, with a planted violation shown failing.
- Demo/example: not applicable (internal). Language parity: no impact.

## Completion notes

**Premise verified (2026-09-27, `origin/main` at `46d51f14`):** no `sol_cli_json.ml`; `rg -n 'Yojson.Safe.Util|Util\.member' cli/lib cli/bin` listed raising accessors in about twenty files, and `sol_cli_loki.ml:73` read a missing `data.result` as `[]`.

- **One boundary.** `Sol_cli_json` (`cli/lib/base`): `decode ~what`, `read_file ~what`, a total `field` path lookup, option conversions (`string`/`int`/`float`/`bool`/`list`/`assoc`), `require` and `optional` that name the dotted path, and `items`. REFAC-127's private boundary in rollout diagnosis now delegates to it.
- **Conflations fixed -- a read that failed used to read as an answer:**
  - `sol_cli_loki`: a missing `data.result` was "no log lines", and a malformed stream or value pair was dropped. **`sol logs` said nothing was logged when it could not read what was.**
  - `sol_cli_disk_quota`: a missing `usage` decoded as 0, **overstating free space -- the fail-open direction for a capacity check.** Both numbers are now required.
  - `sol_cli_migration.parse_status_json`: an entry whose `applied`/`version` did not parse was dropped, so a malformed *applied* migration read as unapplied.
  - Release and deployment history (`sol_cli_release`, `sol_cli_deployment`): a list response with no `items` was an empty history; a release item with no `creationTimestamp` sorted first as `""` in retention ordering (now required, for retention only).
  - `sol_cli_rollback.workload_rows_of_payload`: no `items` read as "no live workloads", which would report every stale workload as gone.
  - `sol_cli_terraform_outputs.displayable`: a non-object document was "no outputs" (its test pinned that, and now pins the error).
  - `sol_cli_platform_component.layer`: a `components.json` that is not an object, or a component entry that is not one, installed the component with no values. An *absent* component or layer is still the documented empty object.
- **Exceptions out of a decoder:** `Sol_cli_cluster.outputs_reader` let `Json_error` escape to three callers that each caught it; it returns a result and they bind it. The `exception _` catch-alls around a record body (`sol_cli_release`, `sol_cli_deployment`, the whoami decoder) catch only `Json_error` via `decode`.
- **Moved onto the boundary without a behaviour change** (they already failed closed): `release_store` (whose `record` is now a `let*` chain), `boundary_lease`, `secret`, `deployment_store`, `cloud_destroy`, `terraform_plan` (a change with no readable actions stays `Unknown []`, which the plan policy refuses), `aws_destruction`, `gcp_cluster`'s autopilot read, `cmd_cloud_tf`'s unserved-manifest scan.
- **Also:** `Sol_cli_provider_registry.of_root` replaced a process error with "could not read … Terraform outputs"; it now carries the error's own text (REFAC-125's rule).
- **Deliberately left:** the readiness predicates in `sol_cli_cloud_lifecycle` split kubectl `jsonpath` text. They fail safe (an unreadable output is "not ready", never "ready", so the worst case is waiting to the timeout), and their exact argv is pinned against a real kubectl by INFRA-035's `check_readiness_invocations.sh`, so moving them to `-o json` would change a qualified command set. The release record body's lenient field decoding also stays: it is FEAT-071's design, and a malformed field still fails closed through the digest and id re-derivation.
- **Guard:** `check_json_decode_boundary.sh` (no `Yojson.Safe.Util` / `Yojson.Basic.Util` in `cli/bin`, `cli/lib`) with a three-case mutation test; both run in CI.
- **Tests:** `cli/test/test_json.ml`: the boundary itself, plus a malformed/empty pair for Loki results, disk quota, migration status and the release and deployment lists. **Positive control:** the decoder tests, run against `origin/main` in a scratch worktree, fail all four (e.g. `no data.result: a malformed read was accepted`). `test_rollback` gains "a payload without items is an error". `dune test cli/ --force`: 0 failures; format clean.
- **Demo/example:** not applicable (internal). **Language parity:** no impact.
