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
