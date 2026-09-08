# Sun Documentation Truth Audit — 2026-06-22

**Template:** `docs/audits/DOCS_AUDIT.md`
**Previous audit:** `project/audits/2026-06-12_docs_audit.md`
**Previous findings:** DOCS-001 through DOCS-006 → all DONE

**Context:** This audit runs immediately after a session that (a) removed the managed-hosting layer (`sun cloud deploy/releases/logs` and underlying registry/control-plane code) and (b) rewrote the README opening to reflect a self-hosted product identity.

---

## Previous Finding Status

| ID | Finding | Status |
|----|---------|--------|
| DOCS-001 | Tutorial documents old migration tracking table name | Resolved (DONE) |
| DOCS-002 | Tutorial endpoint table lists Prometheus localhost:9090 (not forwarded) | Resolved (DONE) |
| DOCS-003 | Tutorial scaffold file count off by one | Resolved (DONE) |
| DOCS-004 | kafka-eio-service.md config type and topic provisioning claim stale | Resolved (DONE) |
| DOCS-005 | sun-worker.md `WORKER.handle` and `Make(W).run` signatures wrong | Resolved (DONE) |
| DOCS-006 | sun-storage.md `Migration.rollback` and `~table` param undocumented | Resolved (DONE) |

---

## Checks

### 1. Source-of-Truth Alignment

| Check | Result |
|-------|--------|
| Project identity consistent across docs | [~] PARTIAL — README now correctly describes Sun as a self-hosted OCaml platform. ROADMAP.md still includes a "Sun Hosted" deployment lane (`sun cloud deploy`) that references removed code. → **DOCS-008** |
| Status claims match implementation | [~] PARTIAL — WORK_SUMMARY.md top-section ticket table shows FEAT-020 as IN_PROGRESS and FEAT-021/022/023 as REVIEW; all are in DONE. → **DOCS-009** |
| Historical sections labeled | [x] PASS — ROADMAP uses ~~strikethrough~~ ✓ markers for completed phases |
| Terminology stable | [x] PASS |
| No conflicting quickstarts | [x] PASS — README and Tutorial agree on command flow |

### 2. Command Truth

| Check | Result |
|-------|--------|
| Every documented command exists | [x] PASS (after in-audit fix) — `sun cloud deploy/releases/logs` were removed from TUTORIAL.md CLI reference during this audit |
| Documented flags exist | [x] PASS |
| Output promises are true | [x] PASS |
| Local vs CI deploy semantics clear | [x] PASS |
| Docs use Sun commands first | [x] PASS |

**Fixed during audit:**
- TUTORIAL.md CLI reference (line 494-497) listed `sun cloud deploy`, `sun cloud releases`, `sun cloud logs` — all three commands were deleted in today's session. Removed from reference table.
- TUTORIAL.md "Hosted control-plane release history" section (lines 647-666) documented `CONTROL_PLANE_DATABASE_URL` and `CLOUD_REGISTRY` workflow for deleted commands. Section removed.

### 3. Quickstart Reproducibility

| Check | Result |
|-------|--------|
| Prerequisites complete | [x] PASS |
| Install path accurate | [x] PASS |
| Commands run in order | [x] PASS |
| Paths valid from documented working directory | [x] PASS |
| Verification examples match generated code | [x] PASS |

### 4. Generated Documentation

| Check | Result |
|-------|--------|
| Generated README explains ownership | [x] PASS |
| Generated README uses current commands | [x] PASS |
| Generated README has no framework-repo paths | [x] PASS |
| Generated docs explain edit points | [x] PASS |
| Generated docs preserve security posture | [x] PASS |

### 5. Package Spec Accuracy

| Check | Result |
|-------|--------|
| `kafka-eio-service.md` public API | [x] PASS — config type, topic provisioning, and schema registration all accurate |
| `sun-worker.md` public API | [x] PASS — `WORKER.handle` signature correct (includes `~trace_ctx`); `Make(W).run` params correct (includes `?retry_strategy`, `?on_ready`, `?stop`, `?max_messages`) |
| `sun-storage.md` | [x] PASS — `Migration.rollback` and `~table` param documented |
| Deferred features marked | [x] PASS |
| Cross-package deps accurate | [x] PASS |

### 6. Mission and Audience Fit

| Check | Result |
|-------|--------|
| Consistent product promise | [x] PASS — README now clearly states "you own the infrastructure" |
| Architecture explained before tools | [x] PASS |
| Advanced details do not obscure first-use flow | [x] PASS |
| AI-agent-first design concrete | [x] PASS — README now gives a concrete example (`sun new svc` generates compilable code, type checker validates) |
| No overclaiming | [~] PARTIAL — ROADMAP.md still lists "Sun Hosted" as an active deployment lane. → **DOCS-008** |

---

## Fixed During This Audit (not ticketed)

| Item | Action |
|------|--------|
| TUTORIAL.md CLI reference listed 3 deleted commands | Removed `sun cloud deploy/releases/logs` lines |
| TUTORIAL.md "Hosted control-plane" section documented deleted workflow | Section removed |
| `cli/sun/lib/` contained 3 orphaned `.mli` files (`sun_cli_control_plane.mli`, `sun_cli_hosted_url.mli`, `sun_cli_registry.mli`) with no corresponding `.ml` | Deleted |

---

## Findings

### [DOCS-007] — ROADMAP.md "Deployment Ownership Lanes" table references removed Sun Hosted direction

* **Category:** Status Claim / Mission Fit
* **Severity:** Medium
* **Location:** `docs/planning/ROADMAP.md` line 68; also Phase 6 note line 587, Phase 7 section lines 647-663
* **Description:** The Deployment Ownership Lanes table lists "Sun Hosted | Sun | `sun cloud deploy`" as an active lane. Today's session deleted `sun cloud deploy` and the entire managed-hosting layer. Phase 7 historical notes reference `Sun_cli_hosted_executor` and `Sun_cli_hosted_model` which no longer exist in the codebase.
* **Impact:** A developer reading ROADMAP.md gets a false picture of Sun's product direction and may look for modules that don't exist.
* **Remediation:** Remove the "Sun Hosted" row from the deployment lanes table (or mark it as explicitly deferred/removed). Add a note to Phase 7 that the hosted executor spike was subsequently removed as part of the self-hosted refocus. Update the Phase 6 "Sun-hosted executor" note.

### [DOCS-008] — WORK_SUMMARY.md top-section ticket table is stale

* **Category:** Status Claim
* **Severity:** Low
* **Location:** `docs/planning/WORK_SUMMARY.md` lines 14-25
* **Description:** The latest status table shows FEAT-020 as IN_PROGRESS and FEAT-021/022/023 as REVIEW, plus ALPHA-001, ALPHA-002, FEAT-024, HARDEN-001 as READY_FOR_ENGINEERING. All of these are in `project/tickets/DONE/`. Additionally, the previous section (lines 68-74) still describes the four deployment lanes including "Sun Hosted" which has been deprioritized.
* **Impact:** Engineers reading WORK_SUMMARY.md to understand current state will see wrong ticket status and a product direction that has changed.
* **Remediation:** Update the top section to reflect that all the post-dogfood tickets are DONE. Add a brief note about the managed-hosting removal and self-hosted refocus as the current direction.

---

## Summary

| Finding | Category | Severity | Status |
|---------|----------|----------|--------|
| DOCS-007 | Status Claim / Mission Fit | Medium | Open |
| DOCS-008 | Status Claim | Low | Open |
| Fixed inline: TUTORIAL.md deleted commands | Command Truth | Critical | Fixed |
| Fixed inline: TUTORIAL.md hosted section | Command Truth | Critical | Fixed |
| Fixed inline: orphaned .mli files | Code Hygiene | Low | Fixed |
