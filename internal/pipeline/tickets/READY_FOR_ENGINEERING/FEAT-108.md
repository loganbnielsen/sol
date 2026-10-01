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

## Part A landed (2026-10-01): what uninstall removes, and what it refuses to touch

`Sol_cli_installation_uninstall` is the decision model the command will be built on, so there is one
definition of what the installation contains — the ticket's own remediation, and the same rule
FEAT-107 followed for the zone.

It reuses `Sol_cli_installation.prerequisite` as the resource vocabulary rather than inventing a
second model, and answers four questions:

- **`removes`** — every durable prerequisite the provider declares, *minus* the delegated zone
  unless the **declaration** says Sol owns it. A user-supplied or externally delegated zone is never
  in the removal list, whatever the root's state holds. This is the acceptance criterion "a test
  fails if uninstall removes a user-supplied zone", expressed as a property of the plan rather than a
  comment.
- **`retains`** — what is kept and why, in the words the run will show: a zone the operator supplied
  ("Sol did not create it and does not remove it"), and the registrar NS records, which live outside
  every provider API Sol can call.
- **`unmanages_the_zone`** — the ambiguity rule from the ticket's remediation. When the target says
  the operator supplied the zone but the durable root's *state* owns it, a whole-root destroy would
  delete it. The plan says so, and the command's mechanism is `state_rm` first: the zone survives and
  the run reports that it was taken out of state. Sol never guesses which side is right; it refuses
  to destroy what the declaration does not claim.
- **`dns_confirmation`** — the exact domain when a Sol-created zone is going away, with
  `confirmed_dns_zone_matches` failing closed: no confirmation, or a different domain, never matches.
  That is the separately-confirmed DNS removal the ticket requires.

**Evidence:** four cases in `cli/test/test_installation.ml` (29 total) — a Sol-created zone is removed
and needs its own confirmation naming the domain; a user-supplied zone is never removed and needs
none; a zone the declaration disowns is unmanaged only when the state owns it; an unobservable
answer is reported as a failed observation rather than as absence.

## What remains (part B)

The command surface itself: `cli/bin/cmd_uninstall.ml` registered in `main.ml` with `--confirm` and
`--confirm-dns-zone <domain>`; the destroy of the durable root with the `state_rm` step for an
unmanaged zone; absence verified by observation after removal (the installation's own probes, which
fail closed, plus `Sol_cli_destroy_verification`'s residue model where it fits) with the retained
resources named in the output; a CLI surface test driving fakes for the refusals, the retained zone
and the verified absence; and the documentation the ticket's demo/example line requires
(`docs/DEVELOPER_EXPERIENCE.md` §3/§10, DOCS-029, the `examples/pluto` walkthrough), then a
regenerated `docs/reference/cli.md`.

**Language parity:** no impact — installation removal is app-language neutral.
