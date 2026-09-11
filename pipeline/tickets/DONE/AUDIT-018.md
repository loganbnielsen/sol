---
id: AUDIT-018
type: audit-finding
severity: low
source: project/audits/2026-06-10_audit.md
branch: AUDIT-018/tutorial-stale-facts
worktree: ../sun-AUDIT-018-tutorial-stale-facts
---

Tutorial Documents Stale Patterns and Incorrect File Counts

**Depends on:** None.

**Description:** Three stale facts in `docs/guides/TUTORIAL.md`:

1. **File count wrong** (line 80): "This generates 19 files." The CLI prints "Done. 21 files generated." and `new_workspace` issues 22 `write` calls (the two CI workflow files added since the tutorial was written are not listed).

2. **Ack-before-processing in code sample** (lines 168–175): The worker code sample shows `ack ()` called before `Notification.insert` — the ack-before-processing anti-pattern. The actual generated scaffold (`ws_worker_ml`) correctly calls `ack()` after the DB insert.

3. **Stale NodePort reference** (line 240): "Sun detects that `charge_svc` exposes a NodePort and prints the port-forward command." Services now use `ClusterIP`; the NodePort bug was fixed in AUDIT-004.

**Impact:** AI agents and developers reading the tutorial will reproduce the ack-before-processing pattern. The NodePort claim misleads users about the security model. File count discrepancy erodes trust in documentation accuracy.

**Remediation:** Update `docs/guides/TUTORIAL.md`:
- Line 80: change "19 files" to "21 files"; add `.github/workflows/deploy.yml` and `.github/workflows/sun-ci.yml` to the file listing.
- Lines 168–175: update worker code sample — move `ack ()` to after `Notification.insert`.
- Line 240: replace with "Sun detects that `charge_svc` is an HTTP service and starts a port-forward in the background."

