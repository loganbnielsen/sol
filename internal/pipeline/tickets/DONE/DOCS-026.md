---
id: DOCS-026
type: documentation
severity: high
title: Write the installation and first-deploy guide
source: docs/README.md documentation roadmap; DEC-057 and docs/DEVELOPER_EXPERIENCE.md §3-5 (2026-09-29)
---

**Depends on:** INFRA-096, FEAT-106, FEAT-122.

`FEAT-122` was added to this line on 2026-10-01 during the page's reconnaissance: the
audience's first cloud-account step — creating the four installation identities from
the policy contract Sol generated — is neither performed nor surfaced by the product,
so the page cannot yet show a reader without Terraform knowledge how to take it. See
that ticket for the evidence. `INFRA-096` and `FEAT-107` are implemented; `FEAT-106`'s
inline installation is landed and its remaining part (driving the environment stages
from `sol deploy`) is recorded in that ticket.

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

## Completion notes (2026-10-01)

The page is `docs/guides/installation.md`, written against the flow as it stands
after `FEAT-106` part B: one command does the first run in order — preflight,
installation, environment, the run's own deploy-identity cluster access,
migration, application, endpoint.

**Premise checked at branch start.** All three dependencies are in `DONE`
(`INFRA-096`, `FEAT-106`, `FEAT-122`), and every step the outline asks for is a
step some command performs; nothing in the page shows behaviour marked *Target*
except the one place DEC-058 records as a deferral.

- **Install (§1).** The released tarball, `sol assets` as the install check, and an
  honest table of the tools Sol drives (`aws`, `terraform`, `kubectl`, `docker`,
  `dig`) plus which providers are qualified today — AWS; GCP exists and is not yet
  production-qualified.
- **The two units (§2).** The lifetime table links
  `docs/DEVELOPER_EXPERIENCE.md` §2–3 rather than restating it, and adds the two
  boundaries a reader has to act on: Sol owns the policy *contracts*, the operator
  owns the roles (`AUDIT-072`), and the infrastructure is theirs.
- **Local first (§3).** Points at `TUTORIAL.md` and says what carries over.
- **First production deploy (§4).** The declared target with every field the
  production profile requires, the contracts and how to turn one into a role, the
  deploy command and the ordered stages it runs, the DNS hand-off with
  `--await-delegation`, the one persistent `kube_context` line the *other* commands
  need (and the statement that a deploy run does not need it, DEC-058), the
  provider-without-a-deploy-identity case with DEC-058's trigger for closing it, and
  the unattended/`--dry-run` behaviour.
- **Second deploy (§5).** No one-time setup, and a second target under the same
  installation needs none either.
- **What is yours (§6)** and **teardown (§7)**: destroy vs uninstall as a table,
  with the DNS consequence named — a Sol-created zone whose registrar records go
  stale, and the guarantee that a user-supplied zone is never deleted.
- **The demo/example rule:** §3 and §8 link `TUTORIAL.md` for the local loop and
  `examples/pluto/README.md` as the runnable workspace that carries the same
  first-run walkthrough and is what the CI smoke matrix builds.

Also updated so the set stays consistent: `docs/README.md` marks the page
Published and links it from the getting-started list, the root `README.md`
quickstart paragraph now describes the inline first run instead of calling it
planned, `docs/guides/TUTORIAL.md`'s production section no longer claims the
cluster must already be reachable, and `docs/reference/cli.md`'s note about
inline onboarding names the environment stage too.

**Checks:** every relative link in `docs/` resolves, including the new page's;
`dune build @all` and the ticket guards are unaffected (documentation only).

**Language parity:** no application-facing contract changes — this is a page and
its links — so `DEC-022` carries no per-language verdict for this change.

