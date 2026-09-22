# Fail-open audit — 2026-09-21

**Revision inspected:** `main @ 4ae985f3` (all of PRs #408–#414 landed).
**Scope:** the surfaces where Sol states a *verdict* to the operator or to
qualification evidence — deploy, release retention/rollback, migration gating,
cloud lifecycle, and the `kubectl` diagnosis adapters — plus the CI guard scripts.
**Method:** read the code path that produces each verdict; for every place a
failure/absence/indeterminate read is reachable, determine what the operator (or
the evidence) is told. Findings are `STATIC` unless stated otherwise; the one
positive control run is named where it applies.

**Definition used.** A *fail-open* is any point where a **failure**, an
**unreadable/indeterminate** state, or an **absent** result is presented as
**success, healthy, complete, safe**, or as a **definite negative** ("does not
exist"). The class is not about exceptions in general; it is about the *verdict
rendered to a human or to evidence*.

This audit was commissioned because the class has recurred: FND-0013 (a direct
deploy defaulted `--secret-backend` to the placeholder), FND-0014 (the release
record could not be advanced and the deploy reported success), FND-0017 (a denied
`events` read was shown as "no events"), FND-0021 (a disassociated access policy
was read as removed), and DEC-040 (a `can-i` non-zero exit read as `Denied`).

## Verdict surfaces examined

| Surface | Verdict produced | Result |
|---|---|---|
| `sol status` domain roll-up (`sol_cli_status.ml:36-63`) | healthy / DEGRADED / UNKNOWN / NOT DEPLOYED | **Clean.** `Ns_unreadable` → `UNKNOWN`, `Undetermined` outranks `Healthy`; the deliberate tri-state is in place. |
| `sol cloud apply/destroy` de-escalation (`sol_cli_cloud_lifecycle.ml`, `cmd_cloud_tf.ml`) | Deescalated / Still_elevated / Undetermined | **Clean.** Precedence puts *permitted* first and treats parse failure as `Undetermined`; destroy's check is advisory by DEC-040. |
| `sol deploy` release-record advance (`cmd_deploy.ml:522-553`) | deploy succeeded / failed | **Clean.** A record failure is fatal and explains the un-advanced pointer (DEC-037, INFRA-054). |
| `sol deploy` release pruning (`cmd_deploy.ml:498-555`, `sol_cli_release_retention.ml`) | which records are deleted | **FND-0025** — the previous-release *protection input* is `None` when its read fails, silently weakening a documented guarantee. |
| `sol logs` / `sol fn run` workload existence (`cmd_logs.ml:50`, `cmd_fn.ml:97`) | "not deployed" | **FND-0024** — `probe` collapses "kubectl could not run" into `false`, i.e. "does not exist". |
| Migration gating (`sol_cli_migration.ml:60-62`) | migrations required | **Clean by design.** A *missing* `migrations/` → `Ok []` is documented (`.mli:17-19`) and test-pinned; see FND-0026 for the narrower unreadable-but-present case. |
| `sol logs` Loki parse (`sol_cli_loki.ml:78-91`) | log lines | **FND-0027** (observation) — a malformed/absent stream field is skipped without a trace. |
| `kubectl` lease read (`sol_cli_boundary_lease.ml:199-222`) | lease held / free | **Clean.** Missing/invalid `started_at`/`heartbeat_at` → `Error`, not a default that would look expired. |
| `terraform` presence (`sol_cli_terraform.ml:4-7`) | terraform available | **Clean.** `Error → false` → "terraform missing" → the caller stops; safe direction. |
| CI guards (`internal/ci/*.sh`) | pass / fail | **Clean** for the `|| true` uses inspected: each turns "no match" into empty and the guard then fails on emptiness, rather than swallowing a real failure. |

## Findings

| Finding | Classification | State | Severity | Ticket |
|---|---|---|---|---|
| FND-0024 — `kubectl probe` reports an unreadable cluster as `false`, so `sol logs`/`sol fn` say "not deployed" | `VERIFIED_DEFECT` | `FIXED_UNQUALIFIED` (INFRA-063, 2026-09-22) | low | `INFRA-063` |
| FND-0025 — a failed pointer read drops the previous release's prune protection | `VERIFIED_DEFECT` | `FIXED_UNQUALIFIED` (INFRA-064, 2026-09-22) | medium | `INFRA-064` |
| FND-0026 — a missing *or unreadable* migrations directory both mean "no migrations required" | `OBSERVATION` | `OPEN` | low | — (no ticket) |
| FND-0027 — Loki stream parse failures are dropped without a trace | `OBSERVATION` | `OPEN` | low | — (no ticket) |

### Correction made during this audit

FND-0026 was first written as a `VERIFIED_DEFECT` against the docstring above
`required` — "an unparsable file name is an error rather than a silent skip".
That sentence is about *file names*; the `.mli` documents the missing-directory
`Ok []` as deliberate and `test_required_missing_dir_is_empty` pins it. The first
reading was wrong in the same way the original `omit` reading was wrong
(attributing a nearby sentence to the wrong branch), so it is corrected in the
finding and not filed as a ticket. This is why the positive control was run and
why the `.mli`/test were read before classification.

**Not re-filed (already tracked):** FND-0017 → `INFRA-056` (diagnosis presents a
denied read as "no events"); `INFRA-051` → FND-0014 (release pruning cannot
`list` the set it must read — itself the "diagnose the skip" remedy); `BUG-037`
(the TypeScript Loki push treats a non-network failure as success); `BUG-033`
and `BUG-038` (`pipeline merge-finish` reverts/skips — tooling fail-safes that
mis-report).

## What the common shape is

Both defects share one shape: **a read that can fail is collapsed into the same
value as a legitimate empty/negative answer.** `probe`'s `Error → false` and
`read_previous_release`'s `Error → None` each erase the distinction between
*"the answer is no"* and *"I could not ask"*. (FND-0026 is the same collapse,
but its empty answer is a documented, tested choice, which is why it is an
observation.) The repo has already fixed this shape twice by making the type
tri-state — `ns_presence` in `sol_cli_status.ml` and `capability_answer` in
DEC-040 — and each finding's remedy is that same move: carry the third state
through to the verdict.

## What is not established

- Evidence is `STATIC` (code paths) except for the positive control on
  `Sys.readdir` (FND-0026). No behavioural reproduction was run; each finding
  names the unit-level reproduction that would raise it to mechanism evidence.
- The audit is **scoped, not exhaustive**: it covers the verdict surfaces listed
  above. It does not claim to have enumerated every failure-handling site in the
  repository — an absence, per this repo's own rule, is not a guarantee.
- Whether any of these has already been hit live is not claimed; FND-0014's
  history shows the pruning path *has* failed live for a different reason
  (`list` forbidden), which is why FND-0025's read-failure branch is not
  hypothetical.
