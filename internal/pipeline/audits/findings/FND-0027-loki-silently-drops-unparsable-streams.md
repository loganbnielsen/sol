# FND-0027 — Loki stream parse failures are dropped without a trace

- **Classification:** `OBSERVATION`
- **State:** `SUPERSEDED`
- **First identified:** 2026-09-21, fail-open audit (`2026-09-21_fail-open-audit.md`)
- **Last verified:** 2026-10-02 (`main` @ `1eace495`) — the parser was rewritten
  and no longer discards; see the correction below
- **Derived ticket:** none
- **Evidence class:** `STATIC` (original) → `BEHAVIORAL` (correction)

## Correction (2026-10-02) — the discarded-stream path no longer exists

The observation was written against an implementation that used
`U.member`/`List.filter_map … | _ -> None` and returned `Ok`. The current parser
(`cli/lib/local/sol_cli_loki.ml`) uses `Sol_cli_result.map_list`, which aborts on
the first malformed value, and `Sol_cli_json.require`, which errors on a missing
`values` field. Induced with a stub returning three malformed shapes — a non-pair
value, a stream with no `values`, and a good stream beside a malformed one —
`sol logs` rejected every case with the reason and degraded explicitly:

```text
$ sol local logs --scope payments/charge_svc --no-follow --loki-base-url http://127.0.0.1:3301
(couldn't reach http://127.0.0.1:3301: Loki response: a value is not a [timestamp, line] pair. Falling back to Kubernetes logs for charge_svc...)
```

No partial result is returned and nothing is silently dropped. **State:
`SUPERSEDED`.** The wording of that message is a separate, low defect
(`BUG-123`): a reachable backend's malformed body is reported as "couldn't
reach". Record:
`internal/qualification/records/2026-10-02-observability-run2-local.md` §3.


## What is established

`sol_cli_loki`'s response parse (`sol_cli_loki.ml:78-91`) walks the streams and
collects lines:

```ocaml
List.concat_map
  (fun stream ->
     try
       U.member "values" stream
       |> U.to_list
       |> List.filter_map (fun v ->
         match v with
         | `List [ `String ts_ns; `String text ] -> Some { ts_ns; text }
         | _ -> None)
     with
     | _ -> [])
  streams
```

Three things are silently discarded: a stream with no `values` field (the
`try … with _ -> []`), a `values` entry that is not a two-string list (the
`_ -> None`), and — because the function still returns `Ok …` — any indication
that it happened. Transport failure, a non-`success` status, and a JSON parse
error are all handled as `Error` above this point, so those are fine; this is
about a response that parses as JSON but not into the shape Sol expects.

## Why this is an observation, not a ticket

It is a real silent-truncation path — `sol logs` can print a subset while
looking complete — but there is no stated invariant that `sol logs` output is
guaranteed complete, and a defensive skip of an unexpected entry is a defensible
choice for a log viewer. It sits at the edge of the class (partial → complete),
not at its centre (failure → success), so it is recorded rather than ticketed.
If `sol logs` ever becomes a qualification-evidence input, this should be
promoted and the parse should report a partial result.

## Not established

- Whether Loki can in practice return a `values` entry of another shape for the
  queries Sol issues; no observation of it.
- Whether a partial result is indistinguishable downstream from a complete one —
  the caller prints what it gets, but no comparison was run.

## Related

`BUG-037` — the TypeScript observability push treats any non-network Loki failure
as success, which is the same component one layer over and *is* filed (the
failure → success direction).
