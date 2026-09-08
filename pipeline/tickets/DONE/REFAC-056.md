---
id: REFAC-056
type: audit-finding
severity: medium
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-056/live-variant-constructors
worktree: ../sun-REFAC-056-live-variant-constructors
---

Replace magic `"live"` string literals with `Live`/`Service_live` variant constructors

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_cloud_registry.ml` contains at least four sites where the initial release/service status is hard-coded as the string `"live"` instead of using the existing variant constructors:

| Line | Code |
|------|------|
| 170  | `let status = "live" in` |
| 181  | `Db.exec tx insert_service_q (release_id, name, "live")` |
| 193  | `Printf.sprintf "[deploy] release %s complete: status=live" release_id` |
| 20   | `status TEXT NOT NULL DEFAULT 'live'` (DB schema) |
| 26   | `service_status TEXT NOT NULL DEFAULT 'live'` (DB schema) |

`Sun_cli_registry` already defines `Live` and `Service_live`. The current code bypasses these and writes the string directly into SQL and log messages. If the canonical string representation of `Live` ever changes (or a `string_of_release_status` helper is added via REFAC-055), these literals will silently diverge.

**Remediation:**

1. After REFAC-055 lands and `string_of_release_status` / `string_of_service_status` exist, replace every `"live"` literal with the appropriate call:
   - `let status = string_of_release_status Sun_cli_registry.Live in`
   - `Db.exec tx insert_service_q (release_id, name, string_of_service_status Sun_cli_registry.Service_live)`
2. The DB schema `DEFAULT 'live'` is acceptable as-is since SQL defaults are string-only, but the OCaml code that inserts the value should go through the conversion function.
3. Add a comment to the schema DDL noting which OCaml constructor maps to `'live'`.

This ticket can be done independently of REFAC-055 by inlining the string mapping, but landing REFAC-055 first is preferred to avoid duplicating the conversion logic.

## Review — automated checks passed
All magic "live" string literals replaced with release_status_to_string/service_status_to_string calls; DDL comments added; build clean; no ticket files touched.
