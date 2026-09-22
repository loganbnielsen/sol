# FND-0025 — a failed current-release-pointer read drops the previous release's prune protection

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` — fixed by `INFRA-064` (2026-09-22): the
  previous-release input is three-valued (`Known | None_yet | Unreadable`) and the
  selection refuses to prune on `Unreadable`, reporting the cause, so the protection
  is no longer dropped exactly when its input could not be read. Both readers
  (`cmd_deploy.ml`, `cmd_up.ml`) are fixed. Verified by pure unit tests; a
  qualification run is what would make it `QUALIFIED`.
- **First identified:** 2026-09-21, fail-open audit (`2026-09-21_fail-open-audit.md`)
- **Last verified:** 2026-09-21 (`main` @ `4ae985f3`)
- **Derived ticket:** `INFRA-064`
- **Evidence class:** `STATIC` (code paths)

## What is established

Release retention protects two records explicitly beyond the keep window:

```ocaml
(* sol_cli_release_retention.ml:29-35 *)
let protected release_id =
  String.equal release_id current
  || (match previous with Some p -> String.equal release_id p | None -> false)
```

`select` keeps the newest `keep` records *and* `current` *and* `previous`; `prune`
deletes the rest (`sol_cli_release_retention.ml:41-58`). The CLI documents the
guarantee (`cmd_deploy.ml:1110-1116`):

> Keep the last N release records after a successful deploy (default 20). **The
> current and previous release are never pruned.**

`previous` is read here (`cmd_deploy.ml:495-507`):

```ocaml
(* Read the release the pointer names now, warning rather than failing if it
   cannot be read: it only feeds retention's "protect the previous release". *)
let read_previous_release ctx =
  match Sol_cli_release_store.current ~ctx ~cluster ~workspace with
  | Ok pointer -> pointer
  | Error msg -> eprintf "warning: could not read the current release pointer: %s"; None
```

`Sol_cli_release_store.current` returns `(string option, string) result`, so it
already distinguishes *"there is no pointer yet"* (`Ok None`, a first deploy)
from *"the read failed"* (`Error`). `read_previous_release` collapses the second
into the first by returning `None`, and `None` is exactly what `select` reads as
"there is no previous release to protect".

## Why it is the fail-open class

The comment's premise is inverted. The value being read has **one** consumer, and
that consumer is the protection decision — so a read that fails is precisely the
case where the protection must not be dropped. "Could not ask" is silently
treated as "there is nothing to protect", and the next prune deletes a record the
CLI promises never to pruned. (The same shape as `probe` in FND-0024 and
`required` in FND-0026: `Error` collapsed onto a legitimate empty answer.)

The blast radius is not limited to the second-newest release: `previous` falls
outside the keep window exactly when the pointer is stale — which this codebase
has already observed once. FND-0014 recorded the pointer sitting on an old
release (`r-6d35ecdb…`) while deploys reported success, which is why the pointer
read is not hypothetical here.

## Impact

A deploy can prune the record `sol rollback` would restore, while the deploy
still prints success and the `--keep-releases` help continues to promise the
record is never pruned. The loss is the rollback target, not the running
workload. Medium severity: silent, and it removes the recovery path rather than
the service.

## Not established

- Not observed live. No run has recorded `could not read the current release
  pointer`; FND-0014's live failure was the *prune list* being forbidden, a
  different branch (`INFRA-051`).
- Whether the pointer and the release list can diverge in practice (they are
  different reads) — that is the precondition for the window to matter; the code
  path itself does not depend on it, because the documented guarantee is
  unconditional.

## Reproduction (unit-level, for the ticket)

`Sol_cli_release_retention.select` is pure. Feed it entries where `previous` is
outside `keep`, once with `previous = Some p` and once with `previous = None`, and
assert that the current code prunes `p` in the second case — the exact inversion
of the documented guarantee. A second test at the deploy layer would inject a
failing `Sol_cli_release_store.current` and assert that pruning refuses rather
than proceeds.

## Related

FND-0014 / `INFRA-051` (prune reads a set it may not list — the sibling defect on
the same code path); DEC-037 (the pointer is the record `rollback` restores);
DEC-040 (tri-state as the fix shape).
