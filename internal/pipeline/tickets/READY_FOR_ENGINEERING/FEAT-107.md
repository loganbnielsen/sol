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
