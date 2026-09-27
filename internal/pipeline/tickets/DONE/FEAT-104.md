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

## Completion notes

**Premise re-verified (2026-09-27, `origin/main` `d09d7d87`).** Nothing wrote
`language:`, and the invariant had no producer. Reproduced by running the CLI:

```text
$ sol new workspace probeapp && cat probeapp/sol.yml     # resources only, no services:
$ cd probeapp && sol new svc payments/charge             # sol.yml byte-identical after
```

**What landed.**

- `cli/lib/workspace/sol_cli_sol_yml.{ml,mli}` — the manifest editor.
  `plan ~root ~name ~dir ~language` reads and checks everything and writes
  nothing (so a caller refuses before it creates a file); `commit` writes
  atomically (temp file + rename, keeping the file's mode) and returns
  `Declared` / `Language_added` / `Already_declared`. Nothing is rewritten: the
  patch inserts lines into the text, and the *value* Sol adds comes from
  `Sol_cli_yaml` (REFAC-131), so a name needing quotes gets them. Two safety
  rules: only a block mapping with plain keys is ever patched (a flow mapping or
  a quoted key is refused, naming the file, with the line to add by hand), and
  the text about to be written is parsed back with
  `Sol_cli_config.sol_yml_services_of_string` — if the result would not say
  `language: ocaml` for that unit, nothing is written.
  `Already_declared` writes nothing at all, not even a new modification time.
- `sol new svc|worker|fn` calls it, so the unit it wrote is declared. The entry
  is keyed by the name *discovery* reports — the unit directory's basename,
  `charge_svc` for `sol new svc payments/charge` — which is also how
  `examples/pluto/sol.yml` already spells its five entries; keying by the typed
  argument would have declared `charge` and silently attached to nothing.
- The workspace template (`platform/shared/templates/workspace/sol.yml`) now
  declares the two units it ships. Without this a freshly generated workspace
  was *not* check-clean, because `sol new workspace` creates
  `app/payments/charge_svc` and `app/comms/notify_worker` itself.
- `sol check` warns for a workload that declares no language, naming the unit
  and the line to add. A warning, not an error: the workspace still loads, and
  the command that needs a language refuses it itself.
- `Sol_cli_config.sol_yml_services_of_string ~path text` — the proof-read's
  reader (the same decoder, for text in hand).

**Evidence (real runs, this worktree).**

```text
$ sol new workspace probe && cd probe && sol new worker comms/ledger
  … sol.yml: added ledger_worker, declared language: ocaml
$ sed -n '/services:/,$p' sol.yml
services:
  ledger_worker:
    language: ocaml
  charge_svc:
    language: ocaml
  notify_worker:
    language: ocaml
$ sol check
sol check: ok
```

The new entry is inserted under the existing `services:` key, the template's
comments and its two entries survive byte-for-byte, and a generated workspace
checks clean. `sol check` in `examples/pluto` also prints `ok` with no warnings —
all five entries already declared, so **pluto needed no change**. The warning
the new rule produces on a hand-authored, undeclared workspace is visible in
`internal/fixtures/venus` (both units), which is left as it is: it is a fixture,
not an example, and it now demonstrates the warning path.

**Behaviour changes, stated rather than discovered later.**

- `sol new svc|worker|fn` now requires a Sol workspace: the declaration has to go
  somewhere, and a unit generated outside a workspace could never satisfy the
  invariant. It fails with the workspace-identity error before creating
  anything. Four existing tests scaffolded a bare unit in an empty directory and
  now create the workspace boundary first.
- `sol check` gained a warning (above) — new output for a workspace whose
  workloads predate the declaration.
- `Sol_cli_check.check_workload` is internal to the library; it gained `~manifest`.

**Tests.** 11 new cases for the editor: the three edit shapes (no section, an
entry to an existing section, an entry missing its `language:`), idempotency
(the second registration is byte-identical), a name that must be quoted, and five
refusals (another path, a conflicting language, an unparseable `sol.yml`, a shape
that cannot be patched, an unwritable manifest — each asserting nothing was
written). `cli/test/test_scaffold.ml` gained the end-to-end case: after
`sol new workspace` + `sol new svc`, the manifest says `language: ocaml`, the
reader agrees, the workspace is check-clean, and re-running does not touch
`sol.yml`. `cli/test/test_check.ml` gained the warning and the no-warning cases.
The whole CLI suite, `dune build`, and `check_ocamlformat.sh --all` pass, as do
the offline guards (`classify-changes`, examples self-contained, platform-assets
owner, workflow paths, framework doc signatures, support refs, ticket
transitions).

**Demo/example: the scaffolded workspace is the example**, and this ticket keeps
it in sync — the template declares its own units, the golden scaffold tests and
the tutorial's file listing follow, and `docs/guides/TUTORIAL.md` documents the
contract (a new "Workloads declare their language" section) together with
`docs/reference/substrate.md`'s qualification paragraph. No new example
Dockerfile, so the `example-dockerfile-smoke` matrix is untouched.

**Language parity: this is the declaration's producer**, and it is the input
FEAT-103's dev-loop adapter and FEAT-084's TypeScript scaffolding both consume.
The field already existed (FEAT-088) and the language set is unchanged; nothing
infers a language from `package.json`, `dune`, `tsconfig.json` or a directory
name, and no runtime contract (wire format, retry/DLQ, metric vocabulary,
lifecycle, secrets) changes.
