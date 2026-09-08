---
id: REFAC-055
type: audit-finding
severity: high
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-055/typed-release-status
worktree: ../sun-REFAC-055-typed-release-status
---

Thread `release_status` variant through `update_release_status` instead of raw string

**Depends on:** None.

**Description:**

`sun_cli_registry.ml` defines `release_status` as a proper variant (line 4–8):

```ocaml
type release_status = Queued | Building | Live | Failed
```

But `update_release_status` discards this at line 105:

```ocaml
let update_release_status t release_id status_str =
  ...
  let status = match status_str with
    | "failed"   -> Failed
    | "building" -> Building
    | "live"     -> Live
    | _          -> Queued   (* silently treats any unknown string as Queued *)
  in
```

And the Postgres adapter mirrors it at `cmd_cloud_registry.ml:269`:

```ocaml
let pg_update_status pool release_id status_str =
  match Db.exec pool update_status_q (status_str, release_id) with ...
```

The control-plane vtable type in `sun_cli_control_plane.ml` exposes `update_release_status : release_id -> string -> (unit, string) result`, propagating the raw string all the way to callers.

The consequence: callers must know the exact lowercase strings `"live"`, `"failed"`, `"building"`, `"queued"`. A typo silently resets any release to `Queued`. There is also an `Abandoned` state that may be added later but cannot be safely introduced without updating every string-match site.

**Remediation:**

1. Change `Sun_cli_registry.update_release_status` signature to accept `release_status` instead of `string`. Delete the string-to-variant match inside the function body — the caller now supplies the variant directly.
2. Add `string_of_release_status : release_status -> string` to `sun_cli_registry.ml` for the Postgres adapter to use when writing to the DB column (the DB column remains TEXT; the conversion happens only at the persistence boundary).
3. Update `pg_update_status` in `cmd_cloud_registry.ml` to accept `release_status`, call `string_of_release_status` just before the SQL bind.
4. Update the `registry_ops` vtable field type and all call sites.

## Review — automated checks passed
All checks green: build clean, string_of_release_status exported, update_release_status accepts variant, all call sites use constructors, tests pass.
