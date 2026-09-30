---
id: DOCS-028
type: documentation
severity: high
title: Write the end-to-end deployment guide for a customer cloud
source: docs/README.md documentation roadmap; DEC-057 and docs/DEVELOPER_EXPERIENCE.md §5-6, §8 (2026-09-29)
---

**Depends on:** None.

**Related:** `DOCS-026` (installation, the prerequisite), `DOCS-029` (operations),
`docs/deployment/escape-hatches.md`, `docs/deployment/production-bootstrap.md`,
`docs/deployment/compatibility.md`, `docs/reference/substrate.md`,
`FEAT-109` (CI bootstrap), `DEC-016`/`DEC-031`/`DEC-032` (target addressing),
`DEC-020` (the destination comes from the target, not the shell).

## What this page is

One page that takes a workspace from "it runs locally" to "it is deployed in my
AWS or GCP account", covering the supported deploy modes and the decisions a user
actually makes. It is the production counterpart to the tutorial's Part 8, which
is currently the only narrative and mixes several levels of detail.

Today the material is spread across `docs/deployment/production-bootstrap.md`
(operator-level bootstrap and identity), `docs/reference/substrate.md` (the
substrate contract), `docs/deployment/escape-hatches.md` (`sol.toml` overrides),
and the tutorial. None of them is the single end-to-end path an app author
follows.

## Audience

An operator or senior developer who has an installed Sol, a workspace, and a cloud
account, and wants a deployed environment: provisioning the substrate, deploying
the application directly or through GitOps, and setting up CI.

## Outline

1. **Choose a target** — the addressing model
   (`sol deploy <env>/<driver>/<region>`), why the environment is a property of
   the target and there is no `--env` (`DEC-016`), and how the destination is
   resolved from the target, not the shell (`DEC-020`).
2. **Provision the substrate** — `sol cloud plan`, `apply`, `destroy`; what each
   owns; the profile and compatibility constraints.
3. **Deploy the application** — direct mode (`sol deploy <target> --image-tag …
   --registry …`) and GitOps mode (`--emit-to`), with the trade-off stated.
4. **CI** — the supported workflow and short-lived identity (`FEAT-109`,
   DOCS-026's install page for the workspace setup).
5. **Escape hatches** — link `escape-hatches.md` for `sol.toml` and the
   self-managed levels rather than restating them.
6. **What Sol generates vs what you bring** — link `substrate.md`.
7. **Compatibility and profiles** — link `compatibility.md`; state plainly which
   languages and providers a production profile admits today.

## Sources of truth to link, not copy

- Target addressing: `DEC-016`, `DEC-031`, `DEC-032`.
- Substrate inputs: `docs/reference/substrate.md`.
- Bootstrap, identities, recovery: `docs/deployment/production-bootstrap.md`.
- Overrides: `docs/deployment/escape-hatches.md`.
- Profile/language admission: `docs/deployment/compatibility.md`.

## Acceptance criteria

- A reader can go from a local workspace to a deployed environment using this page
  and the CLI, with no source checkout.
- Both direct and GitOps modes are covered, and the page says which to choose and
  why.
- The page does not duplicate `escape-hatches.md`, `substrate.md` or
  `production-bootstrap.md`; it links them.
- Current limitations (provider/language/profile) are stated, not implied away.
- Every command shown is real on current `main`, and any Target behaviour is
  marked with its ticket.
- `docs/README.md` marks this page Published.

## Notes

- Keep `production-bootstrap.md` as the operator detail page; this guide is the
  narrative path and should link down to it rather than absorb it.
