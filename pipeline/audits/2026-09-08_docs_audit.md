# Sol Framework: Documentation Truth Audit — 2026-09-08

First docs-audit since 2026-06-22 (nearly three months). In that window: the full `sun`→`sol` rename (FEAT-032), the four-part directory reorg (REFAC-071..074: `kafka-eio-service`→`framework/`, `project/`→`pipeline/`, `tools/`→`devtools/`, `platform/`→`cli/platform/`), several hosted-mode architecture decisions (DEC-005/007/008/009/010), and a new TypeScript package layer (`packages/sol-kafka`, `packages/sol-obs`) with a migrated `examples/pluto/app/demo_ts` (FEAT-034/035/038/039).

**Previous findings status:** DOCS-007 and DOCS-008 (the only two left open in the 2026-06-22 report) are both in `pipeline/tickets/DONE/`. `soldev pipeline check-reverts` reports clean — no DONE ticket in this repo has a matching revert commit, so both are genuinely resolved, not silently reverted.

## 1. Source-of-Truth Alignment

* [x] Project identity is consistent across README/ROADMAP/TUTORIAL.
* [ ] **Status claims match implementation** — see DOCS-010 (TS packages undocumented) and DOCS-013 (WORK_SUMMARY.md stale since 2026-09-06).
* [x] Historical sections are labeled (WORK_SUMMARY.md is explicitly dated/append-only; no confusion risk from what it does contain).
* [x] Terminology stable across docs.
* [x] No conflicting quickstarts found.

## 2. Command Truth

* [ ] **Every documented command exists, and every real command is documented** — see DOCS-011 (`sol open` is real and registered but undocumented). All 11 other top-level commands (`new`, `dev`, `plan`, `up`, `deploy`, `status`, `logs`, `migrate`, `rollback`, `secret`, `cloud`) are correctly documented in TUTORIAL.md.
* [x] Documented flags spot-checked, consistent.
* [x] Output promises spot-checked (e.g. `sol deploy`'s URL-printing per EXP-029, `sol status`'s image-tag column per the same).
* [x] Local vs CI deploy semantics documented.
* [x] Docs use Sol commands first; the `cli/platform/infra/` Terraform paths mentioned are correctly labeled as advanced/direct-Terraform fallback, not the primary path.

## 3. Quickstart Reproducibility

* [x] Prerequisites stated.
* [x] Install path documented (README Quickstart — separately tracked as EXP-026, not re-audited here since it's an existing open item).
* [x] Command order reproducible.
* [x] Paths valid from documented working directory.
* [ ] **Verification examples match generated code for the primary (OCaml) quickstart** — not fully re-verified live this pass (out of scope for a docs-only audit); no new finding filed since nothing contradictory was found in the text itself.

## 4. Generated Documentation

* [x] Generated README (via `Sol_cli_cmd_new.cmd` / scaffold templates) explains ownership, uses current commands, has no framework-repo paths — consistent with REFAC-071's verified `sol new workspace` output.
* [x] No findings this section.

## 5. Package Spec Accuracy

* [x] Spot-checked `framework/sol-svc/sol-svc.md` against `service.mli` — consistent (`Service.Make` functor documented matches implementation).
* [ ] Full per-package spec-vs-mli sweep not exhaustively performed this pass (time-boxed); no contradiction found in the packages checked.

## 6. Mission and Audience Fit

* [x] Consistent "write business logic; Sol handles infrastructure" framing across README/ROADMAP.
* [ ] **New TypeScript package layer is invisible to the stated audience** — see DOCS-010. The user has stated this TS demo path is meant to be the framework's showcase; right now nothing in the primary docs tells a reader it exists.

## Findings Log

### [DOCS-010] — TypeScript packages (`@sol/kafka`, `@sol/obs`) and the TS demo are undocumented in all primary docs
* **Category:** Status Claim / Mission Fit
* **Severity:** Medium
* **Location:** `README.md`, `docs/guides/TUTORIAL.md`, `docs/planning/ROADMAP.md` (absence, not a false claim)
* **Description:** `packages/sol-kafka/`, `packages/sol-obs/`, and the migrated `examples/pluto/app/demo_ts/{order_svc,fulfillment_worker}` (built today via FEAT-034/035/038/039, with a real live cross-service trace-linked run proving they work) are not mentioned anywhere in README.md, TUTORIAL.md, or ROADMAP.md. Grepping for `sol-kafka`/`sol-obs`/`demo_ts`/`typescript` in those three files only matches the unrelated OCaml `framework/sol-obs` package.
* **Impact:** This is explicitly meant to be the framework's TypeScript showcase per today's direction. A reader of the primary docs has no way to discover it exists, undermining its purpose before it's ever shown to anyone.
* **Remediation:** Add a section to README.md (or a dedicated `docs/guides/TYPESCRIPT.md` linked from README/TUTORIAL) introducing `@sol/kafka`/`@sol/obs`, pointing at `examples/pluto/app/demo_ts/README.md` for the runnable example, and noting these are in-tree packages (not yet published to npm), matching this repo's own established language for the OCaml `*-eio` extraction pattern.

### [DOCS-011] — `sol open` is a real registered command, undocumented anywhere
* **Category:** Command Truth
* **Severity:** Low
* **Location:** `cli/sol/bin/cmd_open.ml` (implementation); absent from `README.md`, `docs/guides/TUTORIAL.md`, `docs/planning/ROADMAP.md`
* **Description:** `sol open` (opens Grafana logs/metrics/dashboard views in a browser, with `--scope`/`--observability-backend`/`--base-domain` flags) is registered in `cli/sol/bin/main.ml`'s command group alongside all other top-level commands, but every other command has TUTORIAL.md coverage while this one has none.
* **Impact:** A real, working day-2-operations command is invisible to anyone reading the docs — they'd have to already know it exists (e.g. from `sol --help`) to use it.
* **Remediation:** Add `sol open` to TUTORIAL.md's CLI reference alongside `sol logs`/`sol status`, documenting its scope options and what it opens.

### [DOCS-012] — `docs/audits/DOCS_AUDIT.md` template itself uses stale pre-rename paths
* **Category:** Status Claim
* **Severity:** Medium
* **Location:** `docs/audits/DOCS_AUDIT.md` — e.g. line 31 `cli/sun/bin/main.ml`, line 47 `cli/sun/bin/cmd_new.ml`, line 63 `cli/sun/lib/sun_cli_scaffold.ml`, section 5's `framework/kafka-eio-service/*.md` reference, and throughout uses `sun new`/`sun dev` command examples.
* **Description:** Same class of issue as `AUDIT-066` (filed against `docs/audits/AUDIT.md` earlier today): the audit template's own source-location pointers predate the `sun`→`sol` rename and today's reorg, so every future docs-audit run has to manually re-derive current paths instead of following the template directly. This audit run worked around it by reading current source directly rather than trusting the template's stated paths.
* **Impact:** Compounds with every future docs-audit — the exact gap AUDIT-066 already identified for the technical-audit template, just not yet fixed for this one.
* **Remediation:** Update `docs/audits/DOCS_AUDIT.md`'s source-location references to current paths (`cli/sol/bin/`, `cli/sol/lib/sol_cli_cmd_new.ml`, `framework/kafka-eio-service/`, `framework/*/*.md`) and command examples (`sol new`, `sol dev`, etc.), mirroring whatever fix lands for `AUDIT-066`.

### [DOCS-013] — `WORK_SUMMARY.md` hasn't been updated since 2026-09-06, missing two full days of significant work
* **Category:** Status Claim
* **Severity:** Medium
* **Location:** `docs/planning/WORK_SUMMARY.md` (top section, last entry "FEAT-032 — sun -> sol rename (2026-09-06)")
* **Description:** `.claude/CLAUDE.md`'s own Documentation Protocol requires updating `WORK_SUMMARY.md` "at task completion" to reflect what was accomplished. The file's most recent entry is FEAT-032 (2026-09-06). Everything since — DOCS-009, AUDIT-064/065, OBS-044, the FRIC-006..014 series, DEC-008/009/010, and today's entire four-part reorg (REFAC-071..076) plus the TypeScript framework-parity effort (FEAT-033..039) — has no entry.
* **Impact:** Anyone reading `WORK_SUMMARY.md` to understand "what's happened most recently" (its stated purpose) gets a two-day-stale picture, missing the single largest structural change to the repo (the reorg) and the newest showcase feature (the TS packages). This is the same category of staleness `DOCS-008` already flagged and fixed once for an earlier gap in this file.
* **Remediation:** Add a new top entry to `WORK_SUMMARY.md` summarizing 2026-09-08's work (the reorg, REFAC-075's merge-tooling fix, the TS packages/dogfood effort, and this docs-audit), then keep it current going forward per CLAUDE.md's existing instruction — this is a process-adherence gap, not a one-time doc fix.

## Summary

| Finding | Category | Severity | Status |
|---------|----------|----------|--------|
| DOCS-007 | Status Claim / Mission Fit | Medium | Resolved (confirmed via check-reverts) |
| DOCS-008 | Status Claim | Low | Resolved (confirmed via check-reverts) |
| DOCS-010 | Status Claim / Mission Fit | Medium | Open |
| DOCS-011 | Command Truth | Low | Open |
| DOCS-012 | Status Claim | Medium | Open |
| DOCS-013 | Status Claim | Medium | Open |
