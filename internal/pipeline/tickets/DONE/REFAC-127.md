---
id: REFAC-127
type: refactor
severity: medium
title: Kubernetes JSON decoding in rollout diagnosis reports malformed input instead of reading it as "nothing there"
source: operator review (2026-09-26, sol-logan-comments), cli/lib/kube/sol_cli_rollout_diagnosis.ml
---

**Depends on:** None.

## The problem

`parse_pods_json` and the events and cronjob parsers in `sol_cli_rollout_diagnosis.ml` turn anything unexpected into `[]`:

```ocaml
let parse_pods_json (s : string) : pod_status list =
  try
    match member_opt "items" (Yojson.Safe.from_string s) with
    | Some (`List items) -> List.map parse_pod items
    | _ -> []
  with
  | _ -> []
```

So malformed JSON, a missing `items` field, or any exception reads as "there are no pods". That is the conflation FND-0024 and DEC-038 §7 forbid: a read that failed is not an answer about the cluster. The operator flagged each `| _ -> []` ("Non Empty List? Maybe they're constructed from maybeNoneEmptyList"), `parse_cronjob_status`'s `0, []` default ("maybe this type should be different as a whole?"), and `format_pod_diagnosis`, which matches on `p.state` twice ("why discard other payload field?").

## Remediation

- Decoders return `(_, string) result`: `Ok []` only when the API said the list is empty, and `Error` for malformed or missing structure. The caller already has `Events_unavailable`/`Undetermined` states to carry the error (DEC-038).
- No `try … with _ ->`. Catch `Yojson` errors specifically, at the decode boundary.
- `parse_cronjob_status`: make "no active jobs" and "status not reported" distinct in the type, rather than `0, []`.
- `format_pod_diagnosis`: match the state once and render the headline and details from that one match.
- Non-empty types only where "at least one" is the meaning (REFAC-123's rule).

## Acceptance criteria

- Tests: malformed JSON and missing `items` are `Error`; `{"items": []}` is `Ok []`. `sol status`/`sol logs` show a malformed read as "diagnosis unavailable: …", not as healthy.
- `git grep -n 'with _ ->\|with\n *| _ ->' cli/lib/kube/sol_cli_rollout_diagnosis.ml` is empty, or each remaining match is justified in the notes.
- Demo/example: not applicable (internal). Language parity: no impact.

## Completion notes

**Premise verified (2026-09-26):** on origin/main, `sol_cli_rollout_diagnosis.ml` had 10 `| _ -> []` / `try` catch-alls. `parse_pods_json "not json"` returned `[]`.

- **One decode boundary.**
  - `decode` catches `Yojson.Json_error` only.
  - `items` requires the response's `items` to be a list of objects.
  - Below that, field access goes through a total `field` path lookup (absent, or not an object, gives `Null`), so nothing can raise.
- **Results, not empty lists.**
  - `parse_pods_json` and `parse_events_json` return `(_, string) result`.
  - `Ok []` only when the API answered with an empty list.
  - A malformed read reaches the states that already existed for it: pods give `Undetermined`, events give `Events_unavailable`, the CronJob gives `Unavailable`, which becomes `Undetermined`.
- **`parse_cronjob_status` returns a `result`.**
  - Kubernetes omits `status.active` when no job runs (omitempty), so an absent list is the true answer "none active", not a sentinel.
  - A non-list `active`, or an active job with no name, is an error; before, such entries were dropped.
  - `active_count` is gone: it only restated `List.length active_job_names`.
- **`format_pod_diagnosis`** matches the state once, producing the headline and detail together.
- **A bug the catch-all hid:** `J.member` raises on `Null`, so one pod missing `metadata` made the whole pod list read as empty. It now parses with defaults (test).
- **Tests.**
  - Malformed input is `Error` for all three decoders; an empty list is `Ok []` (the positive control).
  - A pod without metadata parses.
  - Mutation control: restoring the old "malformed is `[]`" behaviour in `parse_pods_json` fails `malformed is Error` ("pods: not JSON").
- **Grep criterion:** `grep -nE 'with _ ->|\| _ -> \[\]|\btry\b' cli/lib/kube/sol_cli_rollout_diagnosis.ml` prints nothing; the same pattern on origin/main counts 10.
- **Verification:** 66 CLI suites pass; format is clean.
- **Demo/example:** not applicable (internal). **Language parity:** no impact.
