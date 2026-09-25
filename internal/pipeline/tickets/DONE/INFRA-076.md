---
id: INFRA-076
type: bug
severity: high
title: Terraform must survive Sol, with durable output, a supervisor that records completion, and a graceful signal boundary
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** INFRA-075.

**Related:** DOCS-022, REFAC-094, HARDEN-004

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S4. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

**Premise verified 2026-09-24:** `Sol_cli_process.run` gives Terraform stdout/stderr pipes only Sol reads (`cli/sol/lib/sol_cli_process.ml:184-196`) and `Sol_cli_run_log.run_phase` writes the phase log only after exit (`sol_cli_run_log.ml:188-207`). Reproduced locally with `terraform_data`: closing the wrapper's read end kills Terraform with SIGPIPE (rc −13 after 5.1 s), leaves the lock held, and loses the in-flight resource from state.

**Sequencing:** preferred after DOCS-022, but not blocked on it; supervision is justified whatever DEC-045 decides. REFAC-094 must not merge before this ticket is `DONE`.

## Remediation

One design unit (plan § S4): Terraform output to durable files Sol tails; a supervisor that outlives Sol, launches Terraform in its own session, and records `{pid, host, started_at}` then the exit status or terminating signal; one SIGINT to Terraform's pid only on interrupt (never to provider plugins, never by name, no SIGKILL/timeouts, never force-unlock); three operation states, **Running / Resolved / Unresolved**, as defined in the plan (a graceful non-zero exit after Ctrl-C is Resolved); `errored.tfstate` detected, preserved and reported, never auto-pushed; a clear message when Sol exits while Terraform continues and holds the lock. The qualification harness adopts the same process-identity rules.

**First decision:** the test provider. `terraform_data` has no plugin process, so it cannot prove plugins are not signalled; use a tiny in-repo test provider with a slow Create, or a vendored `null`/`time` provider, hermetically.

## Acceptance criteria (offline)

- The SIGPIPE failure reproduces against the old path and no longer occurs.
- Sol killed mid-apply: Terraform continues, output keeps being written, exit status recorded, lock released, state complete.
- One Ctrl-C reaches Terraform only; the provider plugin process receives no signal from Sol.
- Running / Resolved / Unresolved each classified correctly, including graceful non-zero → Resolved; Unresolved refuses an ordinary constructive retry.
- `errored.tfstate` → loud failure, file preserved.
- Unrelated Terraform processes are untouched.
- `internal/qualification/*` no longer uses `pkill -f` or force-unlock.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes (2026-09-25)

**Mechanism.** `Sol_cli_supervised` (new): every lock-taking Terraform command (`plan`,
`plan_saved`, `plan_destroy`, `apply`, `apply_saved`, `destroy`, `state rm`) runs under a supervisor.
The supervisor is this binary re-invoked as `sol __supervise` (dispatched first thing in `main.ml`),
forked with `setsid` into a session of its own. It launches Terraform with stdout/stderr going to
files in an operation record (`$XDG_DATA_HOME/sol/operations/<key>/<op>/`), records Terraform's pid
(and `/proc` start time, so a recycled pid is not mistaken for it), waits, and writes the outcome
(`exited N` / `signaled N`, POSIX numbering) atomically. Sol only waits and reads the files. On
INT/TERM/HUP, Sol sends **one SIGINT to Terraform's pid only**; a second interrupt is forwarded as
Terraform's documented cancel, labelled as possible data loss; later ones are ignored. There are no
timeouts, no SIGKILL, and no unlock anywhere. The record's key is the root plus its backend
configuration, as `init` last configured it, because every target of a provider shares one root.

**Operation states.** `Running` (no outcome; supervisor or Terraform alive on this host, or started
on another host, which is never read as abandoned); `Resolved` (an exit status was recorded,
**including a graceful non-zero exit after Ctrl-C**, and no `errored.tfstate`); `Unresolved`
(killed by a signal; no outcome and nothing alive; or `errored.tfstate` in the root). At the start of
`sol cloud plan|apply|destroy`, `guard_previous_operation` refuses on `Running` for every command. On
`Unresolved` it refuses `apply` (cloud and platform roots) unless `--accept-unresolved` is given,
which also records the acknowledgement; `plan` and `destroy` warn and proceed. The existing backend
lock stays authoritative; no second lock was invented. `errored.tfstate` is reported loudly with its
path right after the failing run, preserved, and never pushed.

**Test-provider decision.** Not a real plugin. The property under test is Sol's: it signals exactly
Terraform's pid and nothing else. A fake `terraform` shell script records signals it receives and runs
a child standing in for a provider plugin, which records its own. A **positive control** (SIGTERM to
Terraform's process group, i.e. Attempt 6) shows that child does record a group signal, so "received
nothing" is an observation that could have failed. That real plugins ignore SIGINT is upstream
behaviour, already established from go-plugin's source (`server.go`, "Eat the interrupts"). This keeps
CI hermetic, with no Go toolchain or provider download.

**Evidence.**
- `cli/sol/test/test_supervised.ml` (8 cases): pure classification; clean run (durable stdout);
  **Sol SIGKILLed mid-apply** → Terraform keeps writing, finishes, and is `Resolved`/exit 0, with no
  signal received (the SIGPIPE failure is gone); **SIGINT to Sol's whole process group** (a terminal
  Ctrl-C) → Terraform gets exactly one SIGINT, the provider stand-in nothing, an unrelated process is
  untouched, and a graceful exit 1 is `Resolved`; positive control; self-kill by signal →
  `Unresolved`; `errored.tfstate` → `Unresolved`, file preserved, acknowledgement clears it;
  supervisor and Terraform both killed → `Unresolved`.
- **Before** (the old path, recorded in the 2026-09-24 due-diligence investigation, not in-repo): a
  wrapper that launched `terraform apply` the way `Sol_cli_process.run` did, then closed its pipe read
  ends, saw Terraform exit with **rc −13 (SIGPIPE) after 5.1 s**, the lock left held and the in-flight
  resource missing from state. The Sol-death case above is the same scenario after the change.
- `internal/ci/test_cloud_lifecycle_offline.sh`: every scenario now runs the real binary through the
  supervisor. A new INFRA-076 scenario covers: an operation marked signal-killed → `apply` refused, no
  apply ran; `--accept-unresolved` → proceeds and records the acknowledgement; a live supervisor →
  `apply` refused as still running.
- Found and fixed while testing:
  - a relative `XDG_DATA_HOME` would have put the record in Terraform's working directory, so the
    record directory is now always absolute;
  - an empty supervisor start time (written wherever `/proc` does not exist, e.g. macOS) made a live
    supervisor read as dead.
- `dune test cli/sol/test/` exit 0; `check_ocamlformat.sh --all` clean;
  `internal/qualification/gcp/test-live-qual.sh` 24 passed; the real `~/.local/share/sol` untouched
  (21 runs, no `operations/`).

**Qualification harness.** `live-qual.sh stop` no longer sleeps 3 s after `kill -TERM -<pgid>`. That
TERM now reaches only the harness and `sol`, which forwards one SIGINT to Terraform, so the harness
waits for the whole process group to exit before destroying, and never force-unlocks. No `pkill -f`
or force-unlock remains under `internal/qualification/`.

**Docs.** `docs/deployment/production-bootstrap.md` § Recovery: what Ctrl-C does, that `sol` exiting
does not mean Terraform exited, the three states, `--accept-unresolved`, and that a held lock is not
stale just because `sol` exited.

**Behaviour change an operator will notice.** After Sol is killed, Terraform may still be running and
holding the lock; the next command says so instead of failing on the lock.

- Demo/example: not applicable (cloud lifecycle internals; no app-author surface).
- Language parity (DEC-022): no application-facing impact.
- Unblocks REFAC-094 (plan § S5b), which must not merge before this is on `main`.
