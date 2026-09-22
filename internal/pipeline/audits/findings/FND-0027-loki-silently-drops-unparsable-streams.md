# FND-0027 — Loki stream parse failures are dropped without a trace

- **Classification:** `OBSERVATION`
- **State:** `OPEN`
- **First identified:** 2026-09-21, fail-open audit (`2026-09-21_fail-open-audit.md`)
- **Last verified:** 2026-09-21 (`main` @ `4ae985f3`)
- **Derived ticket:** none (see below)
- **Evidence class:** `STATIC`

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
