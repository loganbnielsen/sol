---
id: INFRA-064
type: bug
severity: medium
title: Never drop the previous-release prune protection when the pointer read fails
source: audit finding FND-0025 — fail-open audit 2026-09-21
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0025-prune-loses-previous-protection-on-unreadable-pointer.md`

**Depends on:** none.

**Related:** `INFRA-051` (the same retention path, from the other side: the prune
*list* may be unreadable because `list` is not granted). Whichever lands first
should not have to be revisited by the other; both want the same shape — a prune
that is *skipped and diagnosed* rather than silently narrowed.

## The defect

`--keep-releases` promises (`cmd_deploy.ml:1110-1116`):

> The current and previous release are never pruned.

`Sol_cli_release_retention.select` implements that with a `previous` input
(`sol_cli_release_retention.ml:29-35`): the guarded set is the newest `keep`
records plus `current` plus `previous`. `previous` comes from
`cmd_deploy.ml:495-507`:

```ocaml
let read_previous_release ctx =
  match Sol_cli_release_store.current ~ctx ~cluster ~workspace with
  | Ok pointer -> pointer
  | Error msg -> (* warning *) None
```

`Sol_cli_release_store.current` returns a `result`, so `Ok None` ("no pointer
yet") is already distinct from `Error msg` ("could not read"). Returning `None`
on `Error` collapses them, and `None` is exactly what `select` reads as "there is
no previous release to protect" — so the guarantee is dropped precisely in the
case where the protection input could not be read. The comment's premise ("it
only feeds retention's protect-the-previous-release") is inverted: that one
consumer is why the read must not default.

This is not hypothetical for the *pointer*: FND-0014 recorded the pointer sitting
on an old release while deploys reported success, and a stale pointer is when
`previous` falls outside the keep window — i.e. when the protection actually
changes the outcome.

## Impact

A deploy can prune the release record `sol rollback` would restore, while the
deploy prints success and the option's help still promises the record is never
pruned. The running workload is unaffected; the recovery path is what is lost.
Medium severity: silent, and it removes the safety net rather than the service.

## Remediation

Make the read tri-state and let `select`/`prune` take the third state, the same
move `sol_cli_status.ml` (`ns_presence`) and DEC-040 (`capability_answer`) already
made:

1. `read_previous_release` returns an explicit variant, e.g.
   `Known of string | None_yet | Unreadable of string`, instead of `string option`.
2. `prune` refuses when the previous release is `Unreadable` — report a diagnosed
   skip ("could not determine the previous release; not pruning this time"), the
   same outcome `INFRA-051` asks for when the list itself is unreadable. Under-
   pruning is safe; the guarantee must not depend on a read that failed.

## Acceptance criteria

1. With a failing `Sol_cli_release_store.current` and a successful release list,
   a deploy prunes nothing and says why.
2. `Ok None` (a first deploy) still prunes normally.
3. `Sol_cli_release_retention.select` unit tests cover `previous` inside and
   outside the keep window, so the "never pruned" guarantee is pinned by a test
   rather than by a comment.
