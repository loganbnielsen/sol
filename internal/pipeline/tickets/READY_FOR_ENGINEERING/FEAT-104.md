---
id: FEAT-104
type: feature
severity: medium
title: Generated workloads declare their language - sol new records language in sol.yml
source: operator review (2026-09-27), out of the FEAT-103 dev-loop design - "language is becoming something Sol knows explicitly about a workload, and sol new should record it because Sol just created the thing"
---

**Depends on:** None.

**Related:** FEAT-103 (the dev loop that needs the declaration and depends on
this ticket), FEAT-084 (TypeScript scaffolding, which must honour the same
contract and will add language *selection*), FEAT-088 / FEAT-089 (the declared
language's reader and the production-profile compatibility check).

## The invariant

> **Every workload has a declared language, and Sol never guesses one.**

`sol.yml`'s `services.<name>.language` is already the declarative place
(FEAT-088) and the platform already refuses to infer it from build metadata
(FEAT-089: "inferring the language from Dockerfiles, paths, package metadata or
other build details" was explicitly rejected). What is missing is a *producer*.

Language is becoming the input to more than the compatibility check — FEAT-103's
local dev loop is the first command that cannot act at all without it (it must
choose a build/run adapter), and scaffolding, build strategy, dependency
preparation and diagnostics are all downstream of it. So the declaration has to
be present wherever Sol creates a workload.

## Evidence (real run, 2026-09-27, CLI built from `47286fba`)

```text
$ sol new workspace probeapp
$ cat probeapp/sol.yml
# Sol workspace manifest.
… resources:
    app_db: { type: postgres }
    events: { type: kafka }          # no `services:` block at all

$ cd probeapp && sol new svc payments/charge
  … created  app/payments/charge_svc/{bin,lib}/… sol.toml
$ cat sol.yml                        # byte-identical to before
```

`sol new` has no language concept anywhere (`rg -n 'language'
cli/lib/workspace/sol_cli_cmd_new.ml` → no matches), it never writes `sol.yml`,
and the only workspaces that declare a language today are hand-written ones —
`examples/pluto/sol.yml`, whose five entries carry `language: ocaml|typescript`.
So a freshly scaffolded workspace satisfies the manifest schema but violates the
invariant, and FEAT-103's loop (which must not infer) would refuse every unit in
it.

## Remediation

- When `sol new svc|worker|fn <domain>/<name>` creates a unit, register it in the
  workspace `sol.yml` under `services:` with `language: ocaml` — the answer is
  known, because Sol just wrote the unit. Entry shape follows the operator's
  sketch and the existing examples: the bare unit name as the key, `language:`
  as the load-bearing field. (`type:`/`path:` are optional in the schema and are
  not needed for the declaration; add only what a reader actually uses.)
- The write must be safe on a hand-maintained file: preserve comments, key order
  and untouched entries; be idempotent (re-running does not duplicate or
  reformat); write atomically (no partial file on failure); and where the file
  cannot be patched, fail with an error naming `sol.yml` rather than corrupting
  it. If no `services:` section exists, add one.
- Refuse a creation whose bare unit name is already declared for a different
  path, naming the conflict: the manifest keys services by bare name today, so
  two domains with the same unit name would otherwise be silently mis-declared.
- Establish the invariant for hand-authored units too: `sol check` reports an
  *undeclared* workload as a warning naming the unit, the file and the line to
  add (`language: ocaml | typescript`). Not an error — loading a workspace must
  keep working for a workspace that has not declared yet (FEAT-089 already
  degrades an undeclared language to "unknown" rather than failing).
- No `--language` flag here: the scaffold creates OCaml, so it records OCaml.
  Selection belongs to FEAT-084, which then records what it created.

## Acceptance criteria

- After `sol new workspace w`, `cd w`, `sol new svc payments/charge`, `w/sol.yml`
  declares `charge_svc` (or the unit's own name) with `language: ocaml`, and
  `Sol_cli_config`/the workspace model report `language = Some Ocaml` for it —
  a test asserts the loaded declaration, not just the file text.
- Tests cover: no `services:` section yet; a section with other entries and
  comments (both preserved, verified by comparing the file before/after); a
  re-run over an already-declared unit (unchanged); a name already declared for
  another path (refused, naming it); an unwritable `sol.yml` (error naming the
  file, the original file intact).
- `sol check` warns on an undeclared workload in a workspace that has one, and
  stays silent for `examples/pluto` (all five declared).
- Demo/example: the scaffolded workspace *is* the example, so the golden scaffold
  tests and the tutorial stay in sync in this ticket; `examples/pluto` already
  declares all five workloads and should need no change (state in the completion
  notes whether it did). A hand-authored unit is documented as declaring its
  language once, in the tutorial's local-iteration section.
- Language parity: this is the declaration FEAT-084's TypeScript scaffolding and
  FEAT-103's adapter both consume; it changes no runtime contract (no wire
  format, retry/DLQ, metric vocabulary, lifecycle or secret semantics).
