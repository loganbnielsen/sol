# FND-0026 — a *missing or unreadable* migrations directory both mean "no migrations required"

- **Classification:** `OBSERVATION`
- **State:** `OPEN`
- **First identified:** 2026-09-21, fail-open audit (`2026-09-21_fail-open-audit.md`)
- **Last verified:** 2026-09-21 (`main` @ `4ae985f3`)
- **Derived ticket:** none (see "Why this is not a ticket")
- **Evidence class:** `STATIC` + a positive control (below)

## Correction to the first reading

The first pass called this a defect, on the strength of the docstring directly
above `required`:

> An unparsable file name is an error rather than a silent skip: a migration the
> deploy would not require is exactly the failure this check exists to prevent.

That docstring is about **file names**, not about a missing directory. The `.mli`
documents the directory case as deliberate (`sol_cli_migration.mli:17-19`):

> `[Ok []]` when `[dir]` does not exist (the workspace has no migrations, so
> nothing is required); `[Error]` on a file name that does not carry a numeric
> version.

and `test_migration.ml:79-86` (`test_required_missing_dir_is_empty`) pins it — so
"missing dir ⇒ nothing required" is an intentional, tested behaviour, not a slip.
The first reading was wrong the same way the original `omit` reading was wrong:
it attributed a nearby sentence to the wrong branch. Recorded here because the
audit's value is accuracy, not ticket production.

## What is established

`required` (`sol_cli_migration.ml:60-62`) is:

```ocaml
let required ~dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> Ok []      (* ← the observation *)
  | arr -> (* … parse *.sql, Error on an unparsable name … *)
```

`Sys_error` is raised for **any** directory-read failure, not only "no such
directory". Positive control run during this audit:

```
$ ocaml /tmp/probe.ml
raises Sys_error: /nonexistent-sol-fail-open-audit: No such file or directory
```

The same exception type is what `EACCES`/`ENOTDIR` raise, so the single catch
covers both the documented case ("there is no `migrations/` — the feature is
unused") and an unexpected one ("`migrations/` exists but cannot be read").

Callers treat `Ok []` as a definite answer: `cmd_migrate.ml:988` →
`No_migrations`; `cmd_deploy.ml:355` treats `Ok []` as "nothing to report".

## Why this is not a ticket

The narrow gap is real (`EACCES` reads as "no migrations") but:

- the `ENOENT` case is deliberate, documented and test-pinned, so this is not a
  defect in the intended behaviour;
- there is no evidence an unreadable-but-present `migrations/` occurs in
  practice — the workspace owns the directory, and the paths that matter are
  created by `sol new`;
- per the audit ticket policy, "an improvement might be useful" is not grounds
  for a ticket.

It is recorded so that a future reader (or a future finding about a skipped
migration gate) has it, and so the distinction between the two `Sys_error`
cases is explicit rather than latent.

## If it is ever promoted

The minimal correct shape is to narrow the catch to `ENOENT` and let any other
`Sys_error` propagate as `Error`, keeping the documented `Ok []` for the
intentional case. The unit test is already in the tree to keep the deliberate
branch honest.

## Related

`INFRA-051` / FND-0014 (another place where "could not read the set" and "the set
is empty" meet); FND-0024, FND-0025 (the same `Error → empty` collapse, where the
answer *does* reach a verdict).
