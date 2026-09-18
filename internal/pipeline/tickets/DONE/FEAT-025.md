---
id: FEAT-025
type: feature
severity: high
source: docs/planning/LIVE_DEV_DEPLOY_ROADMAP.md
---

Harden `Sun_cli_config` core parsing: `.mli`, fail-loud on malformed/ambiguous input, fix silent corruption.

**Depends on:** None.

## Problem

`cli/sun/lib/sun_cli_config.ml` already implements the bulk of
`LIVE_DEV_DEPLOY_ROADMAP.md`'s "Project 3: Target Files" — `sun.yml`
parsing, `target_of_path`, `target_file`, `load_for_target` merge — and is
already consumed by `cmd_plan.ml`, `cmd_cloud_tf.ml`, and
`sun_cli_observability_url.ml`; `cli/sun/test/test_config.ml` reads its
record fields directly. This ticket is the *core* hardening pass — new
parsing features (DynamoDB per-index keys, `aws:`/`gcp:` boxing) are
`FEAT-028`; `uses`-reference validation and absolute cross-region refs are
`FEAT-029`; both depend on this one.

Confirmed against the current code:

1. **No `.mli`.** Internal plumbing (`upsert_by_name`, `merge_by`,
   `strip_comment`, …) is accidental public surface. The `.mli` must expose
   `t`/`target`/`resource`/`service` as **concrete records** —
   `test_config.ml` and callers read fields directly today.
2. **Duplicate `<name>:` blocks within one section of one file are
   silently merged, not rejected** (`upsert_by_name`, line 99). (A target
   overlay legitimately overriding a base-file entry of the same name is a
   different, unaffected code path — this is about two blocks with the
   same name inside *one* file.)
3. **Unknown keys are silently dropped** at every indent level (every
   `| _ -> current`/`r`/`s`/`()`).
4. **An empty-valued key at indent 2 is misparsed as a name header.**
   `2, _, _ when ends_with ~suffix:":" body` (line 158) fires on *any*
   indent-2 line ending in `:`, including a bare `registry:` (no value) —
   it gets treated as the start of a new resource/service block instead of
   a key with a missing value.
5. **`root` is never reset when a `target:` header is seen** (line 153).
   If `target:` appears after `resources:`/`services:` in the file, stale
   `root` state misroutes subsequent indent-2 lines under `target:` into
   `resources`/`services` as phantom entries.
6. **`strip_comment` cuts `#` inside quoted values** (line 48, blind
   `String.index_opt s '#'`) — `path: "app/core/api#1"` silently truncates.
7. **`parse_int`/`parse_bool` swallow garbage instead of failing** (lines
   92–97). `parse_int "abc"` returns `None` via `try ... with _`, so `min:
   abc` silently becomes "unset"; `parse_bool` treats any non-`"true"`
   value — including a typo like `"TRUE"` — as `false`, silently.
8. **`target_of_path` doesn't reject `..` segments.**
   `target_of_path "../../etc"` — a *3-segment* path — produces a
   well-formed `target` whose `target_file` (`Filename.concat` chain)
   escapes `sun/`. (Note: a `/`-containing segment is already impossible —
   `String.split_on_char '/'` guarantees no segment contains `/`; don't add
   a check for that.)
9. **`load_for_target` discards root `sun.yml`'s own `target:` block's
   non-identity fields.** `Ok (merge { base with target = Some target }
   overlay)` (line 333) replaces `base.target` wholesale with the bare
   path-derived identity before merging in the overlay — any `registry`/
   `base_domain`/etc. in root `sun.yml`'s own `target:` block, intended as
   a workspace-wide default, is thrown away. Fix: merge `base.target`'s
   non-identity fields with the path-derived identity first, *then* layer
   the overlay on top.
10. **Item 3 (fail loudly on unknown keys) must not break two shapes this
    ticket doesn't own the structure for yet, and must not break a real
    fixture.** `test_config.ml`'s `by_expires_at` index (indent-8
    `partition_key`/`sort_key` under an index name) and any `aws:`/`gcp:`
    boxed sub-section under `target:` are `FEAT-028`'s job to give real
    structure to — until it lands, both stay in their *current* tolerated-
    but-ignored state; item 3's fail-loud rule applies to every other
    unrecognized key, not to these two specific, already-tracked shapes.
    Separately, `examples/pluto/sun/prod/aws/us-east-1.yml` has a real,
    committed `resources.app_db.size: small` — `size` is
    `LIVE_DEV_DEPLOY_ROADMAP.md`'s "resource sizing" field
    (`resources, resource-specific shape` / line 88's "resources, indexes,
    backups, and scale" list). Add `size : string option` to `resource`
    and parse it (store only — no consumer needs it yet, same as several
    other fields `Sun_cli_config` already stores for `cmd_plan.ml` to
    print) so this fixture doesn't turn into a parse error under item 3.

## Remediation

1. Add `cli/sun/lib/sun_cli_config.mli` per item 1. Verify `cmd_plan.ml`,
   `cmd_cloud_tf.ml`, `sun_cli_observability_url.ml`, and `test_config.ml`
   all still compile against it (adjusting `test_config.ml` only where a
   later item in this ticket changes actual parser behavior it exercises —
   not "unchanged," several of these fixes change what currently-passing
   inputs do).
2. Fix items 2–9 above. Each is independent; land as separate commits
   within the PR if that helps review.
3. Add `resource.size` per item 10, and confirm items 2–3's fail-loud rule
   explicitly excludes the two `FEAT-028`-owned shapes named in item 10.
4. Tests: one per numbered item (2–10), each proving the old silent
   behavior is now either correct, unaffected (the two excluded shapes),
   or a loud `Error`. Include `examples/pluto/sun/prod/aws/us-east-1.yml`
   itself (or an equivalent fixture) as a regression test — it must still
   parse successfully end to end after this ticket lands.

## Acceptance criteria

- `dune build` succeeds; the `.mli` names only the surface listed in item 1.
- A duplicate `<name>:` block, an unknown key, a bare `registry:` with no
  value, an out-of-order `target:` block, a `..`-containing target path,
  and a malformed `min:`/`omit:` value all fail to parse with a specific
  error — none of them silently succeed or silently drop data.
- `path: "app/core/api#1"` round-trips intact.
- A root `sun.yml` `target:` block's `registry` survives into a resolved
  target even when the target-file overlay doesn't set one.

## Closed — implemented outside the ticket pipeline

Merged directly to `main` (PR #96 for FEAT-025 "Harden target file parser", PR #97 for FEAT-028 "Model target provider fields and index keys") by a parallel session before this ticket was picked up here. Verified post-merge against this ticket's acceptance criteria: `.mli` added with concrete records, `resource.size`, `index` type with `partition_key`/`sort_key`, `target.provider_fields`, quote-aware `strip_comment`, duplicate rejection (resources/services/sections/provider boxes/index names), fail-loud unknown keys, `parse_int`/`parse_bool` returning `Result`, `..`-traversal rejection in `target_of_path` — all present. Moved to DONE for bookkeeping accuracy rather than left in `READY_FOR_ENGINEERING` describing already-shipped work.
