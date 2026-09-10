---
id: INFRA-007
type: feature
severity: medium
source: DEC-012 (Apache-2.0 licence decision) — the hygiene that makes it real
---

**Depends on:** None (DEC-012 is decided and the licence file is in place).

Complete the open-source hygiene the Apache-2.0 choice implies. `LICENSE` exists and the manifest metadata is set; these are the pieces that keep the project clean and the decision reversible.

## Items

- **DCO before contributions land.** Add a `CONTRIBUTING.md` requiring commit sign-off (`git commit -s`) and enforce it in CI (the DCO GitHub App, or a small workflow checking `Signed-off-by` on PR commits). Rationale: while the author owns 100% of the repository, relicensing any component is trivial; once outside patches land it requires every contributor's consent. This is the one item that gets expensive if deferred, so do it before the repo is promoted.
- **Trademark.** Record who owns the "Sol" name and logo and how they may be used (a short `TRADEMARK.md`, or a line in the README, is enough to start). Apache-2.0 explicitly excludes trademark rights; the README already states this.
- **Copyright holder.** The licence currently names the individual author. If an entity is formed, assign the copyright to it and state it consistently in `LICENSE`, `NOTICE` and the package manifests.
- **Dependency licence audit.** Inventory the licences of what the repo *ships* and what it *deploys*. Known consideration: the platform installs Grafana, Loki and Tempo, all **AGPL-3.0**. Deploying them into a customer's own cluster is normally fine (no modification, the customer operates them), but "hosting AGPL software on a customer's behalf" belongs in a legal review before the hosted tier is sold. Cover opam dependencies, npm dependencies, and any bundled charts or images.
- **Distribution.** Decide how a self-hoster obtains Sol: publish `packages/*` to npm (currently `"private": true`), publish the OCaml packages to opam, or ship source-only with build-from-source instructions. This is the other half of making "free self-host" a real offer.

## Acceptance criteria

- `CONTRIBUTING.md` exists and sign-off is enforced on pull requests.
- The trademark and copyright-holder questions are recorded in one place.
- A dependency licence inventory exists, with the AGPL components called out and the hosted-tier question flagged for legal review.
- The self-host distribution path is decided and documented (README or the substrate contract).
