---
id: VERIF-006
type: bug
severity: high
title: Suites and guards that pass having established nothing
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
premise: '! rg -q EPERM framework/ocaml/sol-obs/test/test_sol_obs.ml'
---

Suites and guards that pass having established nothing

**Depends on:** VERIF-002, VERIF-004.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`:

- `internal/fixtures/local-demo/test/test_e2e.ml:1289-1294` declares the case *outbox logs reached
  Loki* whose whole body is `match o.ob_loki with None -> ()`; the CI step that runs it documents
  the outcome at `.github/workflows/ci.yml:270` ("LOKI_URL is unset, so the Loki assertions
  self-skip"), while `run_tests.sh` sets `LOKI_URL` and does exercise it.
- `framework/ocaml/sol-obs/test/test_sol_obs.ml:14-18` and
  `framework/ocaml/sol-worker/test/test_worker.ml:240-246` catch
  `Unix.Unix_error (EPERM, "bind", _)` and print
  `[skip] sandboxed environment forbids binding a local socket`, then pass.
- `internal/ci/check_gcloud_interface.sh:13-15` prints `SKIPPED` and `exit 0` when `gcloud` is
  absent, before its eight checks that never invoke `gcloud`. The comment at
  `.github/workflows/ci.yml:418` says it "skips -- loudly -- on runners without gcloud, rather than
  passing"; it passes. GitHub's `ubuntu-22.04` image ships `gcloud`, so PR CI gets the full guard,
  and `internal/ci/run_fast_checks.sh:18` is the path that can silently skip.
- `cli/test/test_scaffold.ml:352-359` runs the rendered workspace's `dune runtest test` with
  `~env:[ "CI", "false" ]` (the BUG-052 fix), so the generated workspace's schema gate is exercised
  only in its skip branch, under a variable that matches neither CI nor staging.

## Problem

Each of these is a case or a guard that reports success without establishing the contract its name
claims. The failure mode is the same in all four: a required dependency, or an environmental
capability, is absent, and absence is interpreted as "nothing to check" rather than "the claim was
not established". The E2E and unit cases are worse than a skip, because the runner reports a passed
case; the gcloud guard aborts its own tool-independent checks, which are the ones that caught real
findings.

## Desired invariant

An omitted dependency produces a distinct, visible, non-passing outcome, or the class does not claim
that contract. A guard that cannot observe its input fails and names what it could not observe; a
guard whose subject does not need the missing tool keeps running without it. A test that cannot
verify its contract is never reported as a passed case.

## Remediation

Split the gcloud guard: keep its static half (impersonation scoping, forbidden broad roles,
provider-tier assignment, declared callers) as a guard that always runs, and make the
argv-versus-`gcloud --help` half fail where `gcloud` is guaranteed (PR CI, which the runner image
provides) with a named, single opt-out for a machine that lacks it. Replace the EPERM skips with a
host requirement the suite reports as unsatisfied. Make the Loki case a real requirement of the
class that runs it — provision Loki for that step, or move the case to the class that has it and
remove it from the one that does not, saying so explicitly. For the scaffolded gate, decide which
environment is authoritative and record it.

## Acceptance criteria

- Running the unit class with `bind()` denied fails and names the host requirement; it does not pass.
- The E2E class with Loki absent fails, or the Loki case is not part of it and the class definition
  says so; no case asserts nothing while reporting a pass.
- `check_gcloud_interface.sh` runs its static checks in every environment, and its interface check
  fails (with an explicit, named opt-out) rather than exiting 0 when `gcloud` is missing.
- No guard or suite reports a pass for a contract it did not observe.
- Demo/example: the E2E fixture and the scaffolded workspace's schema gate are both app-author
  visible; state in one line how each is verified after the change.
- Language parity (DEC-022): check whether the TypeScript golden path has an equivalent
  silently-skipping case and record the outcome in one line.
