# FND-0036 — `sol-jobs`: the claim ignores `kind`, DB errors are invisible without `?ot`, and leases are neither renewed nor fenced

- **Classification:** (a) and (c) `VERIFIED_DEFECT`; (b) `DESIGN_GAP`
- **State:** (a) and (c) `FIXED_UNQUALIFIED` (BUG-044, 2026-09-24: claim by `J.kinds`; startup table check; stderr fallback; failure limit; Postgres-backed tests + mutation checks). (b) `FIXED_UNQUALIFIED` (BUG-050, 2026-09-24: finalize fenced on the claimed attempt; lease loss and overrun logged; renewal stays out of scope).
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `BUG-044` (a and c), `BUG-050` (lease fencing)
- **Evidence class:** `STATIC`. Not run against Postgres: no disposable instance was
  available without guessing credentials on the operator's database. Each item names
  its SQL-level reproduction.

## (a) Two `Make` instances claim each other's jobs — `VERIFIED_DEFECT`

`sol-jobs.md` ("Claim, lease, and retry mechanics") states that `FOR UPDATE SKIP
LOCKED` gives mutual exclusion across *"multiple replicas of the same `-worker`, or
multiple distinct `Make` instances sharing the table"*. The claim query
(`framework/ocaml/sol-jobs/lib/sol_jobs.ml:66-84`) selects on `status`, `run_at` and
`locked_until` only. `kind` is written by `enqueue` but never read by the claim. The
table name is fixed (`:64`).

So with `Make(EmailJob)` and `Make(ReportJob)` both running, either poller claims
either kind. `J.decode` of a foreign payload returns `Error`, which `sol-jobs.md`
treats *"exactly like a `handle` failure"*: retried with backoff, then marked
`'failed'` (`:279-280`, `:235-251`). Jobs die in the wrong worker. If two payload
encodings happen to overlap, the wrong handler **runs** the job. The spec's own model
("an app's `t` is its own sum type covering every kind") is the only safe shape, and
nothing enforces it.

*Reproduction:* enqueue one row through each of two `Make` instances with different
`decode`s, run only the first, and observe the second's row reach `status='failed'`
with the first's decode error in `last_error`.

## (b) Leases are neither renewed nor fenced — `DESIGN_GAP`

`locked_until = now() + lease_s` is set once at claim (`:70`). A `J.handle` that
outlives `lease_s` (default 300s) is re-claimed and **runs concurrently** in another
poller. The finalize statements (`complete_q`, `retry_q`, `fail_q`, `:86-107`) are
keyed on `id` only, so a stale holder's `retry_q` clears `locked_until` while the new
holder is still running, making the row claimable a third time. The spec says
`lease_s` "only needs to comfortably exceed the slowest realistic `J.handle`". That is
an expectation with no enforcement and no signal when it is violated. Fencing the
finalize on `attempts` (the value the claim returned) would make a stale write a no-op.
Whether to add renewal is a design choice.

## (c) Every database failure is invisible without `?ot` — `VERIFIED_DEFECT`

All error reporting goes through `log_warn` (`:211-215`), which does nothing when `ot`
is `None`. That covers a failed claim query, failed completion delete, failed
retry-schedule and failed terminal mark. `ot` is optional. A persistent claim failure
(no `sol_jobs` table because the migration was never written, wrong grants, DB down)
loops every `poll_interval_s` forever (`:267-273`). The loop never exits, never logs
without `ot`, and never fails a health check: a `-worker` that consumes no Kafka topic
gets no probes at all (`sol_cli_manifest_yaml.ml`, `Background_worker, false -> ""`).
A jobs worker whose table does not exist looks identical to an idle one.

*Reproduction:* run `Make(J).run ~pool` without `?ot` against a database with no
`sol_jobs` table. The process stays up and prints nothing.

## Impact

Medium. (a) silently kills or misroutes jobs in the multi-instance shape the spec
explicitly endorses. (c) makes the most common setup error, a missing table, silent.

## Remedy shape

(a) Either filter the claim on the kinds this `Make` handles (`AND kind = ANY(?)`, with
`J` declaring its kinds), or state in the spec and `.mli` that one table admits exactly
one `Make` and detect a foreign `kind` at claim (release it, don't fail it). (c) Log to
stderr when `ot` is `None`. Verify the table at startup and return `Error` from `run`.
Treat N consecutive claim failures as fatal.

## Related

FEAT-077 (sol-jobs), DEC-021; AUDIT-080 (probe rendering).
