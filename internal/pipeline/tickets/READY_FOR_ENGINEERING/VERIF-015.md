---
id: VERIF-015
type: bug
severity: high
title: 'The E2E suite computes one shared fixture before Alcotest runs, and its cases short-circuit when it is degraded'
source: internal/pipeline/audits/2026-10-02_test_suite_audit.md
---

The E2E suite computes one shared fixture before Alcotest runs, and its cases short-circuit when it is degraded

**Depends on:** None.

**Premise verified (2026-10-02)** against `origin/main @ 310917dd`:
`internal/fixtures/local-demo/test/test_e2e.ml:1115-1118` runs `let r = run_golden_path ()` and
`let o = run_outbox_path ()` before `Alcotest.run`; `:263-273` turns a missing `POSTGRES_URL` into
`db_pool = None`; `:156-163` (`truncate_tables`) returns `()` on every error; `:367,:388`
(`| Failure _ -> ()`) discard a worker-fibre failure; `:1090-1091` turns an `http_get` failure into
`None`. Case bodies then short-circuit at `:1144`, `:1151`, `:1160`, `:1167`, `:1175`, `:1184` and
`:1290`:

```ocaml
if r.db_rows = 0 then () else Alcotest.(check int) "3 rows stored" 3 r.db_rows
match r.loki_resp with None -> () | Some resp -> …
match o.ob_loki with None -> () | Some resp -> …
```

`ci.yml:278` documents the outcome for the required PR gate: "LOKI_URL is unset, so the Loki
assertions self-skip."

## Problem

The suite performs its whole expensive path once, outside the test runner, then defines eighteen
cases over the resulting record. When a dependency is absent the cases do not fail — they pass
having established nothing, and the run reports no signal that a group of named cases asserted
nothing. The shared heavy fixture is not the defect; the short-circuit around its absence is. The
same structure also makes a setup failure opaque (`run_golden_path` aborts the process rather than
failing the case it belongs to), and a swallowed `truncate_tables` error means stale rows from an
earlier run can satisfy an assertion. This is the `VERIF-006` shape one level up, and it overlaps
`VERIF-002`: the dependency should be part of the target, not of the ambient shell.

## Desired invariant

A case either establishes the claim its name makes or fails naming the dependency that is missing.
An absent required dependency is never a passing run, and a case whose fixture was degraded is not
reported as passed.

## Remediation

Make the fixture's required inputs explicit and fail-closed: a missing `POSTGRES_URL` (and, for the
cases that claim Loki, a missing `LOKI_URL`) fails rather than degrades. Replace the
`then ()` / `None -> ()` bodies with `Alcotest.fail` naming the dependency. Stop swallowing
`truncate_tables` errors and worker-fibre `Failure`s. Report per-case setup failures instead of
aborting the process before `Alcotest.run`. Fold the dependency provisioning into the class target
so `--force` is no longer the only thing that makes the suite run (`VERIF-002`).

## Acceptance criteria

- Running the E2E suite without `POSTGRES_URL` fails, naming the dependency; it does not pass.
- No E2E case body is a `then ()` / `None -> ()` that reports success.
- A `truncate_tables` failure fails the suite.
- The Loki cases are either hard requirements of the class that claims them or removed from that
  class and recorded as such (`VERIF-006`).
- Demo/example: the E2E fixture is the demo's own test; no separate example change.
- Language parity: no application-facing contract change; state that in one line.
