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
