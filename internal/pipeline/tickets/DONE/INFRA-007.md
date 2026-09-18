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
- The self-host distribution path is decided and documented (README or the substrate contract). **Moved to DEC-013** — it is a decision with commercial consequences (npm scope, name reservation, support expectations), not hygiene work to bundle here.

## Completion notes

**Contributor terms (corrected).** `CONTRIBUTING.md` states the Developer Certificate of Origin as the project's contributor terms — the mechanic (`git commit -s`) and a summary of what the sign-off certifies. It is **deliberately not enforced in CI**. The first version of this ticket added a `.github/workflows/dco.yml` check; it was removed because it verified nothing technical, was trivially satisfiable (filters diligence, not rights), failed on its own introduction, and needed a bootstrap exemption — the signature of ceremony. Enforcement belongs alongside the outside contributors it would govern, i.e. when the project actively solicits them.

The first version also asserted that the sign-off "preserves the ability to relicense later". **That is wrong, and the correction matters.** The DCO is an *origin statement, not a rights grant*: it certifies the contributor had the right to submit under *this* project's licence. It does **not** permit relicensing their contribution under different terms. Every notable relicensing — Elastic, MongoDB, Redis, HashiCorp, Grafana — required a **CLA**. So if the open-core plan (DEC-012/DEC-013) ever needs to tighten the licence, the mechanism is a CLA and a decision to take with counsel *before* contributions are solicited. Nothing a DCO trailer provides.

**Trademark.** `TRADEMARK.md` records that the name and logo belong to the copyright holder and are not licensed by Apache-2.0, with explicit allow/deny lists (truthful reference and attribution are fine; implying endorsement or naming a fork after the project is not).

**Dependency inventory.** `docs/legal/third-party-licenses.md` covers everything `platform/infra/base` and `sol dev up` install, and it turned up two findings worth more than the AGPL note the ticket anticipated:

1. **Redpanda is BUSL-1.1.** Its Helm chart is Apache-2.0, which is the licence anyone checking would see — but the broker it deploys is source-available, and BUSL generally prohibits offering the software as a hosted or managed service to third parties. DEC-008 has Sol running customer infrastructure in Sol's own account, which is precisely that shape. This is now flagged for legal review alongside a concrete fallback (Apache Kafka behind the same schema-registry contract).
2. **The Bitnami image channel changed in 2025.** The PostgreSQL chart is Apache-2.0 and PostgreSQL is under the PostgreSQL Licence, but the free maintained `bitnami/*` images moved to an unmaintained `bitnamilegacy/*` (no CVE fixes) with updated images moving behind a subscription. A currency/supply-chain risk rather than a licence one, and worth deciding deliberately rather than inheriting the chart default.

The AGPL observability stack (Grafana, Loki, Tempo) is documented as the third item: fine to deploy into a customer-operated cluster, and squarely in the same review for the hosted tier.

**Not done, and stated in the document:** the opam and npm dependency graphs are not inventoried — no licence scan runs in CI. That has to happen before either is published, since distribution is what triggers the obligations. Left as an explicit gap rather than implied coverage.

**Addendum (2026-09-15):** the npm runtime trees of the two packages now being distributed externally (`@sol-fab/obs`, `@sol-fab/kafka`, extracted to `loganbnielsen/sol-obs` and `loganbnielsen/sol-kafka`) are inventoried in `docs/legal/third-party-licenses.md` — Apache-2.0 for the packages and `@opentelemetry/api`, MIT for `kafkajs`; no copyleft is shipped or required at runtime. The opam graph and a standing CI licence scan remain open.

**Addendum (2026-09-16): the obligation is now live, and the npm half of the standing scan is closed.**

`@sol-fab/obs@0.1.0` and `@sol-fab/kafka@0.1.0` are published to npm — the
prospective obligation this ticket tracked is now an actual one:

- Both carry `"license": "Apache-2.0"` in their published registry metadata, and
  the assembled tarballs are runnable, so the inventory describes the artifacts
  actually distributed rather than the intended ones.
- **@sol-fab/obs** ships zero runtime dependencies (`@opentelemetry/api` is a peer).
- **@sol-fab/kafka** ships `@sol-fab/obs@^0.1.0` (Apache-2.0) and peers
  `kafkajs` (MIT) / `@opentelemetry/api` (Apache-2.0) — no transitive copyleft.
- A **standing CI licence gate now runs** in both repos:
  `license-checker --production --onlyAllow "MIT;Apache-2.0"`, verified green
  against the real resolved tree in sol-kafka.
- `docs/legal/third-party-licenses.md` remains the inventory of record.

Still open, unchanged: the **opam** graph is not inventoried, and no licence scan
runs for the OCaml side. The Grafana/Loki/Tempo AGPL question still belongs to the
hosted-tier legal review, not here.
