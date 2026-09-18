---
id: REFAC-082
type: refactor
severity: medium
source: review of FEAT-057 (same-cluster check) 2026-09-11 — a third ad-hoc directory walk appeared
---

**Depends on:** None.

One traversal, two policies: share the directory walk between the workspace facts walker and target discovery, so the layout and the failure behaviour are each stated once.

## Problem

Two walkers already exist, and they disagree about failure:

- **`Sol_cli_workspace_scan`** derives facts (topics, migrations, schema subjects) and is deliberately **fail-soft**: `fold_dir` returns `init` when a directory is absent *and* wraps `Sys.readdir` in `try … with _ -> ()`; `filter_validated` warns and drops a bad value; a parse error becomes `[]`. Correct for deriving facts to display; wrong for a safety check.
- **`Sol_cli_manifest.scan_workspace` / `discover_services_result`** returns `(_, discover_error) result` — the shape worth standardising on. (The plain `discover_services` that exits the process when `app/` is missing is the legacy variant.)

FEAT-057 then added a **third** walk inline: `target_paths` in `sol_cli_config.ml`, using relative `Sys.readdir`, hardcoded to `<region>.yml`, returning untyped `env/provider/region` strings, and silently skipping anything it cannot resolve. So three walks, two failure conventions, and in the new one the policy is invisible at the call site — "we could not verify" reads identically to "we verified and it is fine".

## Design

Extract the traversal; leave the policy with the caller. The distinction the current code conflates is the crux:

- **`Absent`** — the path does not exist. Frequently a legitimate domain fact: no `events/` means no topics; no `sol/` means no targets.
- **`Unreadable`** — it exists and cannot be read. Always a failure, and never the same thing as "nothing there".

A small `Sol_cli_fs_walk` with result-returning, **deterministically ordered** traversal:

```ocaml
type error =
  | Absent of string
  | Unreadable of string * string   (* path, reason *)

val entries : string -> (string list, error) result
val dirs : string -> (string list, error) result
val files : string -> (string list, error) result
```

Each caller then states its own policy where it can be reviewed:

- **`Sol_cli_workspace_scan`** maps `Absent → []` and `Unreadable → warn + []`, preserving today's behaviour *visibly* — and testably, which it is not now.
- **Target discovery** propagates both, returning **typed targets rather than strings**, and treats an unresolvable target as an error that the same-cluster check must surface as "could not verify" instead of skipping.

**Ordering** is a second, quieter win: `Sys.readdir` order is unspecified and callers sort ad hoc (`discover_migrations` sorts by name). One deterministic order removes a class of ordering surprises and flaky results.

## Blast radius

`workspace_scan` feeds the deployment plan (topics, migrations, schema subjects) and `sol check`, so the refactor has reach. Existing tests cover those discoverers — `discover_topics` ×8, `discover_migrations` ×4, `schema_subjects` ×4 — which makes it verifiable rather than hopeful: **those suites should pass unchanged**, and if they do not, the refactor changed behaviour it should not have.

## Out of scope

The same-cluster check's **resolution** gap. Comparing config names cannot detect one cluster reached through two names or kube-contexts, so it still misses the case the rule exists for. That needs cluster identity at deploy time — namespace UID or kube-context server URL, recorded per environment — and is tracked separately. This refactor must not be mistaken for closing it.

## Acceptance criteria

- One traversal implementation; no ad-hoc `Sys.readdir` for these paths in `cli/sol/lib`.
- `Absent` and `Unreadable` are distinguished by the shared walker, and the facts walker's fail-soft policy is explicit at its call site.
- Target discovery returns typed targets and typed errors; the same-cluster check reports "could not verify" rather than passing quietly.
- Existing `discover_*` suites pass unchanged; the walker and target discovery gain their own tests.
