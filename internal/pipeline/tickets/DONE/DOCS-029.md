---
id: DOCS-029
type: documentation
severity: high
title: Write the operations and lifecycle guide — status, logs, rollback, check, open, destroy, uninstall
source: docs/README.md documentation roadmap; DEC-057 and docs/DEVELOPER_EXPERIENCE.md §7, §10 (2026-09-29)
---

**Depends on:** FEAT-108.

**Related:** `DOCS-026` (installation), `DOCS-028` (deployment),
`DEC-057` §3/§10 (destroy vs uninstall), `DEC-044` (verified absence), `DEC-042`
(zone lifetime), `FEAT-090` (cloud health, drift, last operation), `OBS-045`
(traces), `INFRA-027` (infrastructure view), `INFRA-051` (release pruning).

## What this page is

The page a user reads after the first deploy: how to see what is running, read
logs, roll back, diagnose, open the right UI, and tear down — in Sol terms, without
dropping into `kubectl` or a provider console for the normal path.

Today these are command help strings and tutorial fragments. The lifecycle
distinction the page must make — environment destroy vs installation uninstall —
has no page, and the uninstall half has no command yet (`FEAT-108`, this ticket's
dependency).

## Audience

An operator running a deployed environment day to day, and a developer diagnosed
with an unhealthy workload.

## Outline

1. **The day-two command set** — a table of `status`, `logs`, `rollback`, `check`,
   `open`, `destroy`, `uninstall` with what each answers and its scope rules
   (including that `sol logs` is deliberately unit-only and why).
2. **Health and status** — `sol status [SCOPE]`, what "healthy" means via
   Kubernetes-derived diagnosis, and the cloud health/drift/last-operation fields
   once `FEAT-090` lands.
3. **Logs** — unit logs, the Loki → `kubectl` fallback and why it exists, and when
   to use `sol open logs` for a wider view.
4. **Releases and rollback** — the release contract and what `sol rollback`
   restores, including the scoped-release boundary.
5. **Diagnostics** — `sol check` against a target/scope, and how to read a failure.
6. **Destroy** — removing an environment through the supported lifecycle, the
   independent absence check, and what is retained.
7. **Uninstall** — the explicit removal of the installation, the DNS consequence,
   and what remains; the environment/installation distinction stated once, clearly.
8. **Recovery pointers** — link `application-data-recovery.md`,
   `credential-rotation.md`, `workload-availability.md`, `migration-ordering.md`
   rather than restating them.

## Sources of truth to link, not copy

- Lifecycle and teardown semantics: `DEC-057` §3/§10.
- Verified absence: `DEC-044`, `DEC-040`.
- Recovery procedures: `docs/deployment/*`.

## Acceptance criteria

- A user can operate a deployed environment for the ordinary path from this page
  alone, without `kubectl` or a provider console.
- Destroy and uninstall are distinguished, and the DNS consequence of removing a
  Sol-created zone is named.
- The logs fallback behaviour is explained honestly, including when it triggers.
- Every command and flag shown is real on current `main`; Target behaviour is
  marked with its ticket.
- `docs/README.md` marks this page Published.

## Notes

- This page waits on `FEAT-108` so that the uninstall section ships true rather
  than describing a command that does not exist.

## Completion notes (2026-10-01)

The page is `docs/guides/operations.md`, published: "Operating a deployed environment".
It follows the ticket's outline section for section — the day-two command table with
per-command addressing and scope rules (including why `sol logs` is unit-only and what to
use instead), health from the cluster's own diagnosis plus the observability reachability
block, the Loki-first snapshot path with its `kubectl logs` fallback and why it exists, the
release/rollback contract (whole-release restore, the `--commit` disambiguation, the
contracting-migration refusal), `sol check` and its exit-status vocabulary, `sol open`,
environment destroy versus installation uninstall, and pointers to the recovery pages.

Every command and flag on the page is real on current `main`, and each **Target** item is
marked with its ticket: cloud health/drift (`FEAT-090`), traces (`OBS-045`),
infrastructure view (`INFRA-027`), and target/scope diagnostics.

The environment/installation distinction is stated once, in §7/§8, with the DNS consequence
of removing a Sol-created zone named and the `--confirm-dns-zone <domain>` spelling shown;
the uninstall half describes the shipped command (`FEAT-108`, merged as part of this work's
predecessor), not a plan. `docs/README.md` marks the page **Published** and links it.

The premise ("today these are help strings and tutorial fragments; the page does not exist")
was checked with `ls docs/guides/` — no `operations.md` existed — and the pages it links
(`docs/guides/deployment.md`, `docs/guides/application-authoring.md`,
`docs/deployment/*`, `docs/reference/cli.md`) are all present; every relative link on the new
page resolves.

**Demo/example coverage:** this ticket *is* documentation, so there is no code or example to
change; the runnable counterpart it points at is `examples/pluto/README.md`'s teardown
section and `docs/guides/deployment.md`.

**Language parity:** no impact — operator documentation; nothing application-facing changes.
