---
id: FEAT-107
type: feature
severity: high
title: DNS onboarding — create or adopt the zone, automate or instruct delegation, then wait and verify
source: DEC-057 and docs/DEVELOPER_EXPERIENCE.md §4.3 (2026-09-29)
---

**Depends on:** INFRA-096.

**Related:** `DEC-042` (the delegated zone's lifetime and ownership, generalised
here from the qualification path to the product), `DEC-043` (durable zone
ownership; resolved by `DEC-057`), `DEC-052` (observe, don't assert), `FEAT-048`
(whether Sol offers an edge/DNS-provider integration), `INFRA-014` (the DNS/TLS
credential path without cloud IAM), `DEC-044` (verified absence).

## What this is

DNS is the unavoidable external boundary in the first deploy. Sol should automate
everything it has authority over and ask the user only for what lives outside that
authority. `DEC-042` decided the *rule* for the qualification subdomains; this
ticket makes the create/adopt/instruct/wait/verify flow a product surface.

Today a delegated zone and its ownership are handled for targets whose
`base_domain` names a zone Sol manages (`create_dns_zone`, `create_route53_zone`),
and otherwise the user is left to infer what to do.

## Required behaviour

- **Accept the production hostname/domain** as part of setup and record where the
  authority for it lies.
- **Create or adopt the managed zone.** Creating a zone Sol will own is a durable
  installation resource (INFRA-096), not an environment resource. Adopting an
  existing zone must not recreate it: a recreated zone gets *different*
  nameservers, silently invalidating a delegation already pasted at the registrar.
- **Automate delegation when Sol manages the parent.** If the parent zone is
  Sol-controlled, create the NS delegation automatically.
- **Instruct precisely when it does not.** When the parent is external, display
  the exact NS records to add, with the target domain named unambiguously.
- **Wait and independently verify public delegation.** Do not treat a written
  configuration as evidence: poll the public/resolver view until the delegation is
  observable, and report it as `Established` only then. An unqueryable answer is
  `UNKNOWN` and fails closed (`DEC-052`).
- **Surface ownership.** State plainly whether the zone is Sol-created (durable,
  Sol-owned), user-supplied, or externally managed with a parent delegation. The
  three cases must not be collapsed into "a zone exists".
- **Preserve across environment destruction.** A delegated zone survives
  `sol cloud destroy <target>` (`DEC-057` §1/§3).
- **Never delete a user-supplied zone.** Ordinary teardown and uninstall both
  preserve it; only a Sol-created zone may be removed, and only by the explicit
  uninstall confirmation in FEAT-108.

## Remediation

- Model zone ownership explicitly, in the same shape `DEC-052` uses: ownership is
  a fact to observe and record, not a configuration assertion about a discoverable
  fact.
- Route the durable zone to the installation's owner (INFRA-096), so target and
  installation never both manage one zone.
- Implement the wait/verify step as an observation with a bounded, reported wait —
  and make the wait's progress visible so the user understands what is pending.
- Explain the external action directly: which records, at which provider, proving
  what. Do not expose internal resolver trivia.
- Record the credential path for DNS-01 where there is no cloud IAM equivalent
  (the token-in-Secret path `INFRA-014` records), so a non-AWS/GCP substrate can
  qualify.

## Non-goals

- Not becoming a general-purpose DNS provider or registrar integrator.
- Not choosing whether Sol offers a third-party edge/DNS integration — that is
  FEAT-048.
- Not the uninstall confirmation flow — that is FEAT-108, which consumes this
  ticket's ownership model.
- Not deleting or migrating a user's existing zone.

## Acceptance criteria

- Setup accepts a hostname and records whether Sol may manage the zone.
- A Sol-created zone has durable ownership, is never recreated by a normal run,
  and survives environment destroy.
- When the parent is Sol-managed, delegation is created automatically; when it is
  external, the exact NS records are displayed.
- Delegation is confirmed by observing public resolution, not by configuration;
  an unobservable answer fails closed.
- The three ownership cases are distinguishable in output and in any
  machine-readable result.
- A user-supplied zone is never deleted by destroy or uninstall.

**Demo/example coverage:** DNS onboarding is user-facing and blocking, so
`docs/DEVELOPER_EXPERIENCE.md` §4.3, the planned installation guide (DOCS-026),
and a runnable walkthrough in `examples/pluto`/the tutorial must show the
create-or-adopt and the "one action required" hand-off.

**TypeScript parity:** No language-parity impact — DNS onboarding is
app-language neutral.

## Premise checked (2026-09-30)

Checked before a worktree, per the ticket rules. The substance holds; two names in this ticket's
own text do not exist, so an implementer should not go looking for them.

**What the code actually has.** The create-or-adopt mechanism is on the **cluster** roots — the
target-disposable ones — not the durable roots, and there is no `create_route53_zone` anywhere:

```text
$ rg -n "create_dns_zone" platform/cloud/gcp/cluster/main.tf
278:  count       = var.create_dns_zone ? 1 : 0
355:  count = var.create_dns_zone ? 0 : 1
362:  dns_managed_zone = var.create_dns_zone ? google_dns_managed_zone.main[0].name : data.google_dns_managed_zone.existing[0].name

$ rg -n "create_route53_zone" -g '!*.md' .
(no matches)
```

So today a zone Sol owns is created by the *environment's* cluster root when its
`create_dns_zone` is true, with a data lookup standing in for adoption when it is false — the
lifetime hazard `DEC-042` and `DEC-043` describe, sitting in the layer that is destroyed with the
environment.

**What INFRA-096 already built, and where this plugs in.** The durable root takes
`manage_dns_zone` (`platform/cloud/aws/bootstrap/variables.tf:16`), the installation models the
zone as the `Delegated_zone` prerequisite (`cli/lib/cloud/sol_cli_installation.ml:22`), and
`Sol_cli_installation_stage` decides `manage_dns_zone` from whether the root's *own state* owns
the zone (`owns_the_delegated_zone`, `cli/lib/cloud/sol_cli_installation_stage.ml:31,74`). What is
missing is exactly what this ticket says: a declaration of who owns the domain, the create/adopt
action, the delegation instruction, and the wait/verify observation. INFRA-096's completion notes
record the same boundary, including that a BYO-DNS target currently reports the zone `Unmet` —
the safe direction, with the wrong reason.

## Slice plan (recorded so the work can land in reviewable pieces)

- **A — the ownership model, and it is what FEAT-108 needs.** Declare where authority for the
  domain lies (the three cases this ticket names) and carry it through the installation model, so
  ownership is a recorded fact rather than an inference: surface it in the `sol cloud bootstrap`
  report and in a machine-readable form, and make the stage's `manage_dns_zone` follow the
  declaration rather than only the existing state. No create and no adopt in this slice — the
  point of A is that FEAT-108 can tell a Sol-owned zone from a user-supplied one. Tests: the three
  cases distinguishable, and a user-supplied zone never adopted or dropped.
- **B — create and adopt, then delegation.** Create only when the declaration claims ownership
  (durable, in the installation, never in the cluster root), adopt an existing zone without
  recreating it, create the NS delegation automatically when the parent is Sol-managed, and
  display the exact records to add when it is not. The `check_durable_dns_zone.py` guard and the
  2026-09-29 adoption record are the existing evidence about this path.
- **C — wait and verify, then preservation.** Poll the public/resolver view with a bounded,
  *visible* wait and report `Established` only when the delegation is observable; an unqueryable
  answer is `UNKNOWN` and fails closed (`DEC-052`). Extend the destroy-boundary test from
  INFRA-096 (which already asserts the durable root is never touched) to the zone's survival by
  name.

**Demo/example coverage** stays as this ticket states, and belongs with slice A's user-visible
surface rather than with the model: `docs/DEVELOPER_EXPERIENCE.md` §4.3, DOCS-026 when it lands,
and a walkthrough in `examples/pluto`/the tutorial for create-or-adopt and the one required
action.

**Language parity:** unchanged — DNS onboarding is language-neutral.

## Part A landed (2026-09-30): the ownership model

Slice A is in the branch that carries this note; the ticket stays `READY_FOR_ENGINEERING` for B and C.

**The declaration.** A target (or the environment it inherits from) says who owns the domain it
serves:

```yaml
prod:
  base_domain: pluto.example.com
  dns_zone_ownership: sol      # sol | user | external
```

`sol` — the installation creates and owns the zone; `user` — the operator created it and Sol never
removes it; `external` — the zone is published elsewhere and Sol asks for the delegation instead of
owning it. A target that declares a domain must declare this: Sol refuses with a message naming the
key and the three values rather than guessing an owner from the fact that a zone exists. A target
that serves no domain declares neither.

**The model.** `Sol_cli_installation.zone` is `No_zone | Service_zone { domain; ownership }`, so the
invariant (ownership exists exactly when a domain does) is the type rather than a convention, and
`owns_the_zone` is the one place that answers "is this the installation's to reconcile". The
ownership is printed in the resolved configuration, so the three cases are distinguishable in the
output and not collapsed into "a zone exists".

**The observations follow the declaration.** A target that serves no domain has no zone
prerequisite at all — it is not "unmet", there is nothing to establish. A Sol-created or
user-supplied zone is looked for at the provider, and a missing one is reported with the declared
ownership in the reason. An externally delegated zone is not looked for anywhere, because it is not
observable where the installation looks: `Sol_cli_installation.probe` gains an `Unverifiable` case
that yields `Unknown` (DEC-052) with a reason naming the domain and the delegation, and the clone of
the provider probe cannot be reached for it (a test drives `observe` with a probe runner that fails
if the domain is ever looked up).

**The stage acts only on what Sol owns.** `manage_dns_zone` is now
`owns_the_zone configuration.zone && the root's own state owns the zone`, so a user-supplied or
externally delegated zone is never created, never adopted and never dropped — and the state read is
skipped entirely for a zone Sol does not own.

**Example and fixtures.** `examples/pluto/sol/environments.yml` declares the three cases across its
four environments (prod and pilot `sol`, dev `user`, customer_cloud `external`), and the
qualification harness and target template carry the key. `docs/DEVELOPER_EXPERIENCE.md` §4.3 shows
the ownership line and states the rule.

**What remains.** B: create and adopt (only when the declaration claims ownership, in the
installation and never in the cluster root), then delegation — automatic when the parent is
Sol-managed, exact records when it is not. C: the bounded, visible wait with public-resolution
verification, and the zone's survival asserted by name in the destroy-boundary test. FEAT-108 needs
A's model and has it; it does not need B or C.

## Create and adopt (2026-10-01)

The durable roots already gate the zone on `manage_dns_zone`, so the remaining work was deciding
that value and adopting rather than duplicating:

- **the declaration decides**: `manage_dns_zone` is `owns_the_zone configuration.zone`, no longer
  "the root's own state already owns it". The old derivation meant a zone the root did *not* yet
  manage could never be created, and — worse — a root whose state *did* own one was told
  `manage_dns_zone=false`, which plans a destroy of a durable resource. The durable-root policy
  refused that plan, so the failure was loud rather than destructive, but the feature did not work.
- **adoption**: when the declaration says Sol owns the domain and the root's state does not own the
  zone, the provider is asked whether a zone for the domain already exists (per provider:
  `aws route53 list-hosted-zones-by-name --dns-name … --query HostedZones[0].Id`, or
  `gcloud dns managed-zones list --filter dnsName=…`). If one does, it is imported rather than
  recreated — the counted address, `aws_route53_zone.qualification[0]` /
  `google_dns_managed_zone.qualification[0]`, because both roots use `count = var.manage_dns_zone
  ? 1 : 0`. If none does, the root creates it. An unqueryable provider CLI is an **error**: without
  an answer, Sol would risk creating the duplicate that DEC-043 forbids.
- **state ownership recognises counted instances**: `owns_the_delegated_zone` matched the address as
  a substring, which worked for `…qualification[0]` by luck and would also have matched
  `…qualification_extra`; it now accepts the address or the address with an instance index.

Covered by the CLI surface test, which drives all three paths against fakes: an existing zone the
root does not own (import of `…qualification[0]` with the observed id), no zone at all (creation,
no import), and a state that already lists `…qualification[0]` (recognised as owned, no import).

**Still open:** the automatic delegation record when the parent zone is in the same account
(AWS `aws_route53_record`, GCP `google_dns_record_set`, with the parent's identity observed by the
CLI and passed as a variable), which is the last piece of the ticket's create/adopt/delegate ACs.
