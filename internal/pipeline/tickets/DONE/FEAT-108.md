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

## Part B landed (2026-10-01): the command, its lifecycle, and its verification

`sol uninstall <TARGET>` is registered in `main.ml` (`cli/bin/cmd_uninstall.ml`), target-addressed
like `sol cloud bootstrap` (DEC-031, DEC-016), with `--confirm`, `--confirm-dns-zone <domain>`,
`--var-file` and `--var`. It reuses the part A model (`Sol_cli_installation_uninstall.plan`) rather
than rebuilding the ownership decision at the CLI edge, and the executor
(`Sol_cli_installation_uninstall_stage`) is a typed injectable-dependency function, as
`Sol_cli_cloud_destroy` is.

**Correction to part A: the identities are not Sol-created.** The durable roots declare the
service/operator policy contracts as `data` sources only — `platform/cloud/aws/bootstrap/main.tf`
has no `aws_iam_role`, the GCP root has none at all, and the AWS outputs say "The operator creates
the role and supplies its ARN". Part A's `removes` listed every non-zone prerequisite, which would
have claimed to delete resources Sol never created (and which Terraform never manages, so the
post-destroy observation would have seen them present and failed every AWS run). `plan` now takes
`created:` — the provider's `installation_created_prerequisites` — so `removes` is exactly the
durable root's own resources (state facility; the zone when the declaration says Sol owns it), and
each identity is reported as retained with the reason "the durable root does not create it; the
operator does, so Sol does not remove it". `Public_delegation` is not a resource at all and is
covered by the zone/registrar line rather than an identity line. The user-supplied-zone property
part A tested is unchanged.

**What a user sees.**

```text
$ sol uninstall qual/aws/us-east-1
Uninstall plan for qual/aws/us-east-1 -- the durable installation that outlives every environment:

  remove  terraform state backend
  remove  terraform state lock
  remove  delegated DNS zone
  retain  qual-aws.example.test -- the NS records at your registrar still point at this zone's nameservers; a recreated zone gets different ones
  retain  provisioning identity -- the durable root does not create it; the operator does, so Sol does not remove it
  ...
  removing the zone for qual-aws.example.test needs its own confirmation, because the delegation at your registrar becomes stale and a recreated zone would have different nameservers: --confirm-dns-zone qual-aws.example.test
error: nothing was removed: removing an installation is destructive, so re-run with --confirm once you intend what the plan above states
```

With `--confirm` (and `--confirm-dns-zone` when a Sol-created zone is going away) the run removes,
re-observes, and prints `Removed and independently observed absent:` followed by `Retained:`.

**Mechanism and ordering.** The durable root is destroyed through `Sol_cli_terraform` (credentials →
`init` → `state list` → destroy), not a parallel destruction path. Two things are taken out of the
root's state *before* the destroy, in this order: the zone when the target declares it is the
operator's but the state owns it (part A's `unmanages_the_zone`), and the state backend. The state
facility is the structural exception: a Terraform root cannot destroy the backend that stores its
own state (Terraform persists state during the destroy walk, so deleting the bucket breaks the run;
that is the mirror of INFRA-096's "a root cannot create the backend that stores its own state"), so
the released bucket is retired explicitly afterwards through the provider — AWS purges every object
version and delete-marker then deletes the bucket; GCP uses `gcloud storage rm --recursive`. Absence
is then established by the installation's own probes (`Sol_cli_installation.observe`), never by the
destroy's exit code: a resource observed `Established` is reported `NOT removed`, an `UNKNOWN`
observation fails closed, and a destroy that failed while every removal is observed absent still
reports success (the ticket's own rule, read in both directions).

**Evidence.** `cli/test/test_installation.ml` (39 total) adds: the identities are retained and the
GCP created-set is state+zone; `classify_removal` maps Unmet→removed, Established→present,
Unknown→unknown, and a missing observation to UNKNOWN; an unconfirmed uninstall and a DNS
confirmation that does not name the exact zone refuse with *no* destructive step reaching the deps;
a user-supplied zone is preserved without any DNS confirmation and is never `state_rm`'d; the
release/zone unmanage both precede the destroy; the observation runs after the destroy and after the
state-backend retirement; and an UNKNOWN observation or a survived state backend fails closed.
`cli/test/test_uninstall_cli.sh`, driven through the real binary with fake `terraform`/`aws`,
pins the same at the CLI edge plus the `state_rm aws_s3_bucket.state` → `destroy` ordering and the
provider retirement argv.

**Premise verified.** `rg -n 'uninstall' cli/bin` returned nothing before this work and now finds
the command; `sol uninstall --help` is registered, and `internal/ci/check_cli_reference.py` reports
the 47-command surface with no drift. The durable-root destroy was never exercised by the
qualification path (the durable roots are only ever *reconciled*, per INFRA-096 part B and
`internal/qualification/aws/live-row.sh`), which is why the backend ordering above is an explicit
mechanism rather than an assumed one.

**Demo/example coverage.** `docs/DEVELOPER_EXPERIENCE.md` §3/§10 now mark uninstall **Today** and
carry the real plan output; `examples/pluto/README.md` gains "Tearing down: destroy an environment,
or uninstall Sol", showing both commands and what each leaves behind; `docs/reference/cli.md` is
regenerated (the planned-command bullet is gone). The operations guide is DOCS-029, which this
ticket makes executable and which is done separately.

**Language parity:** no impact — installation removal is app-language neutral, and nothing here
touches the application contract, framework primitives or generated manifests.

**Recorded limitations.** The probes classify a refused provider command (non-zero exit) as `Unmet`
= absent, so a permission error that is not a 404 verifies as absence; that is the existing
`present_if_output` model shared with `sol cloud bootstrap`, not new here. The live destroy/retire
path was not exercised against a real account — live qualification is a separate, gated ticket per
the qualification ledger, and the offline fakes plus the observation step are the available
evidence. GCS soft-deleted objects (FND-0057) are outside this ticket: the bucket is observed
absent, which is the installation resource, but the soft-deleted objects it leaves are not
individually observed.
