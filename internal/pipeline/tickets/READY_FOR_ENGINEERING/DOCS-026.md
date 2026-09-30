---
id: DOCS-026
type: documentation
severity: high
title: Write the installation and first-deploy guide
source: docs/README.md documentation roadmap; DEC-057 and docs/DEVELOPER_EXPERIENCE.md §3-5 (2026-09-29)
---

**Depends on:** INFRA-096, FEAT-106.

**Related:** `FEAT-107` (the DNS hand-off the page documents), `FEAT-108` (the
teardown the page must distinguish), `DOCS-030` (CLI reference), `DOCS-028`
(deployment), `docs/guides/TUTORIAL.md`, `docs/DEVELOPER_EXPERIENCE.md` §3–5,
`docs/deployment/production-bootstrap.md`, `docs/reference/substrate.md`.

## What this page is

The page a new user reads to install Sol and reach a first deployed service in
their own cloud account. It is the on-ramp for the product, and the counterpart to
the local-path `TUTORIAL.md`: the tutorial is the local loop, this is production.

It does not yet exist as a page. Today's equivalent material is spread across the
README quickstart, the tutorial's production section, and
`docs/deployment/production-bootstrap.md`, which is written for an operator who
already knows the machinery.

## Audience

A capable backend developer with a cloud account, no prior Sol, Terraform or
Kubernetes knowledge, and no source checkout. If the page requires a checkout, or
a step the product does not perform, it has failed.

## Outline

1. **Install** — get the CLI from a release, verify the install, and what the
   binary needs on the machine. State the supported platform(s) honestly.
2. **The two units** — installation vs environment, in the reader's terms (link
   `DEVELOPER_EXPERIENCE.md` §3 rather than restating it).
3. **Local first (optional)** — point at `TUTORIAL.md` for the local loop.
4. **First production deploy** — the guided flow: account/region detection,
   installation, the DNS hand-off, provisioning, platform, application, endpoint.
   Mark the parts that are still Target with their tickets.
5. **The second deploy** — what changes once installation exists.
6. **What is yours** — ownership and portability, in one short section.
7. **Teardown and getting out** — environment destroy vs uninstall, with the DNS
   consequence named.

## Sources of truth to link, not copy

- Installation stages and the lifetime table: `DEC-057`.
- Substrate inputs Sol assumes: `docs/reference/substrate.md`.
- Production bootstrap/identity detail: `docs/deployment/production-bootstrap.md`.
- The status vocabulary: `docs/DEVELOPER_EXPERIENCE.md`'s status key.

## Acceptance criteria

- A reader with an installed release and a cloud account can reach a deployed
  service using only this page and the CLI, with no source checkout.
- Every step the page performs is a step the product performs; Target behaviour is
  marked as such with its ticket.
- One-time installation and repeat deployment are visibly distinct.
- Destroy and uninstall are distinguished and the DNS consequence is named.
- `docs/README.md` marks this page Published.
- The demo/example coverage rule is satisfied: the page's walkthrough matches a
  runnable example or the tutorial.

## Notes

- Split the page rather than letting it become the README: the README keeps a
  short quickstart and links here.
- If the guided flow is not yet built, this ticket waits on INFRA-096/FEAT-106
  rather than documenting a path that does not work.
