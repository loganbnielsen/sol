---
id: FEAT-108
type: feature
severity: high
title: Add `sol uninstall` as the explicit, guarded removal of a Sol installation
source: DEC-057 and docs/DEVELOPER_EXPERIENCE.md §3, §10 (2026-09-29)
premise: "rg -q 'uninstall' cli/bin"
---

**Depends on:** INFRA-096, FEAT-107.

**Related:** `DEC-057` §3 (installation and environment have different destroy
semantics), `DEC-044` (converge and verify absence), `DEC-040` (absence is
observed), `INFRA-082` (what destroying a target means when provider and state
disagree), `SEC-005` (the deploy-identity namespace boundary), `DEC-042` (a
recreated zone gets different nameservers).

## Premise

Checked 2026-09-29 against `origin/main` (acb1b466): the probe is stale exactly
when an `uninstall` surface exists in the CLI. `rg -n 'uninstall' cli/bin`
currently returns nothing, and `sol --help` has no such command, so removing a
durable installation has no supported path today.

## What this is

`DEC-057` §3 splits two operations that were at risk of being conflated:

- `sol cloud destroy <target>` removes one **environment** and leaves the
  installation intact.
- `sol uninstall` removes the **installation** — the durable, account-level
  prerequisites — and nothing else does.

The lifecycle rule is why this is not a tidy-up: `sol cloud destroy` must not
uninstall Sol, and uninstall must not be reachable by accident from an ordinary
environment teardown. Today there is no uninstall path at all, so a user who wants
to stop using Sol has no supported way to remove what the installation created.

## Required behaviour

- **Explicit and separate.** `sol uninstall` is its own operation, never a flag or
  fallback on destroy. It is not implied by destroying every environment.
- **High-signal confirmation.** It states what will be removed and what will be
  retained before doing anything, and requires an explicit confirmation.
- **Special confirmation for externally consequential DNS removal.** Removing a
  Sol-created delegated zone means the NS records at the user's provider become
  stale, and the zone's nameservers cannot be recovered once it is recreated. The
  prompt names the exact domain affected and requires a distinct approval for that
  specific removal.
- **Never remove a user-supplied zone.** A zone Sol adopted rather than created is
  preserved, and the reason is reported.
- **Verified absence, independently.** After removal, Sol observes provider
  reality and reports which Sol-owned resources are absent — not success from exit
  codes (`DEC-044`, `DEC-040`). An unqueryable answer fails closed, never
  "removed".
- **Report retained and externally owned resources.** The result names what was
  intentionally kept (for example a user-supplied zone, or durable state a human
  must confirm is unreferenced) and why.

## Remediation

- Add the command to the CLI and route it through the installation's owner
  (INFRA-096) and zone ownership model (FEAT-107), so there is one definition of
  what the installation contains.
- Reuse the existing verified-absence machinery rather than writing a second
  absence model; where it cannot express an installation resource, extend it there.
- Make the DNS consequence first-class: a Sol-created zone is the one durable
  resource whose removal has a visible external effect, so it gets its own
  confirmation and its own verification step.
- Refuse when ownership is ambiguous, rather than guessing whether a resource may
  be removed (`DEC-057` §3; the fail-closed rule).

## Non-goals

- Not a `decommission` of customer resources. Sol removes what Sol created; it
  reports, and does not delete, what it did not.
- Not `sol cloud destroy`. The two must not become each other's alias.
- Not deleting a user-supplied zone under any circumstance.
- Not cleaning up externally managed registrar NS records: those live outside every
  provider API Sol can call, and remain the human's explicit action.
- Not a hosted-account operation — this is the OSS installation.

## Acceptance criteria

- `sol uninstall` removes the installation's Sol-owned durable resources and
  reports the result.
- Running it does not require destroying environments first, and destroying an
  environment does not imply it.
- The DNS confirmation names the exact domain and is required separately for a
  Sol-created zone; a user-supplied zone is never deleted.
- Absence is established by observation, fails closed on an unqueryable answer,
  and the output names retained/externally owned resources.
- A test fails if an environment destroy removes an installation resource, and a
  test fails if uninstall removes a user-supplied zone.

**Demo/example coverage:** the installation/teardown distinction is user-facing, so
`docs/DEVELOPER_EXPERIENCE.md` §3/§10, the operations guide (DOCS-029), and an
`examples/pluto`/tutorial walkthrough must show both destroy and uninstall and
what each leaves behind.

**TypeScript parity:** No language-parity impact — installation removal is
app-language neutral.
