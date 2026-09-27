---
id: REFAC-143
type: refactor
severity: low
title: Comments in dune files and Dockerfiles, and the comment policy itself
source: operator directive, 2026-09-27, following REFAC-142 (comments removed from OCaml, shell, Terraform and TypeScript)
---

**Depends on:** None.

## What this is

REFAC-142 removed every comment from OCaml, shell, Terraform and TypeScript, and
enforced it with `internal/ci/check_no_comments.sh`. It left dune files,
Dockerfiles and YAML. This ticket takes the two of those that are *not* coupled to
`internal/ci/**` — dune files and Dockerfiles — and records the policy itself in
`AGENTS.md`, so the next contributor (or agent) learns the rule from the docs
rather than from a failed CI step.

The survey that scoped it (`origin/main`, after REFAC-142):

```
dune         68 comment lines / 13 files
Dockerfiles 180 comment lines / 12 files — every one a scaffold, example or fixture file
```

`internal/ci/**`, the CI/workflow YAML coupled to it, the user-facing scaffold and
example YAML, `internal/qualification/**`, embedded Python in CI guards and the
`.tftpl` templates are **out of scope** and stay as they are; the policy records
them as deferred so nobody sweeps them opportunistically.

## Remediation

1. **`AGENTS.md`**: state the policy — covered source and config formats carry no
   comments; required tool directives are the exception; executable invariants
   belong in types, shared definitions, guards or tests; durable rationale
   belongs in documentation, not beside the implementation; user-facing
   explanation belongs in the generated/scaffold documentation rather than being
   silently deleted. Name the deferred categories and their owners.
2. **dune files**: delete the comment lines.
   - `cli/lib*/dune`'s section headers and the repeated "Domains form a DAG …"
     paragraph: recorded in `AGENTS.md`'s repo layout and in DONE/REFAC-104.md.
   - `cli/test/dune`'s rule rationales: carried by the test case names and their
     tickets (INFRA-035/075/076/091, SEC-010, REFAC-115/117, FEAT-089/100).
   - `dune-project`'s DEC-025 block (hand-written `.opam` files, why the generator
     cannot express `pin-depends`, the coordinated release train, hyphenated
     public names): recorded in DONE/DEC-025.md and named in `AGENTS.md`.
   - **Left alone**: the two `cli/test/dune` comments that explain why a guard is
     *not* a dune rule and point at `check_no_account_artifacts.sh` /
     `check_production_infra.sh` — that reasoning belongs with those guards, which
     another agent owns (`internal/ci/**`). Recorded in the completion notes.
3. **Dockerfiles**: delete the comments, and move what they explain to the
   documentation a user actually reads:
   - `platform/shared/templates/workspace/README.md` (ships in the generated
     workspace): a container-images section covering the two stages and the glibc
     pin, that dependencies come from the workspace's own `.opam` (DEC-025), the
     `opam repository set-url` gotcha, why the dependency layer is copied before
     the source, that the build context is the workspace root, and that the image
     runs as uid 65534 to match the rendered pod's `securityContext`.
   - `examples/pluto/app/demo_ts/README.md`: the TypeScript Dockerfiles' build
     context and history (DEC-024/FEAT-085), the npm manifest-first layer, that
     only this service's tree ships while the sibling's workspace symlink dangles
     inert, and the manual `docker build -f … .` recipe.
   - `examples/pluto/README.md`: a pointer for the example's own Dockerfiles.
   - `docs/guides/TUTORIAL.md`: one line where it describes the build step.
   - `internal/fixtures/venus/**`: the comments just go — it is a test fixture, and
     the same explanation now lives in the scaffold README.
4. **The one comment that should become code**: "Run as nobody (uid 65534) —
   matches securityContext in generated k8s manifests" asserts an invariant
   between a template and the renderer (`Sol_cli_manifest_yaml.ml` sets
   `runAsUser`/`runAsGroup` 65534). It becomes a test asserting the template's
   `USER` equals what the renderer emits, so the two cannot drift.

## Acceptance criteria

- No comment lines remain in any tracked `dune`, `dune-project` or `Dockerfile*`,
  except the two deliberately-left `cli/test/dune` notes named above.
- `dune build`, `dune fmt` (no diff) and the CLI and framework test suites pass,
  including the scaffold golden tests, which compare the generated Dockerfile
  with its template.
- The new uid test fails if either the template's `USER` or the renderer's
  `runAsUser` changes without the other.
- Nothing the removed comments explained is lost: each fact is either in a named
  doc, in a ticket/decision record, or in a test.
- **Demo/example**: this ticket's subject *is* the scaffold and example
  documentation, so `/demo-review` runs against the changed artifacts. The
  generated workspace README, the example READMEs and the tutorial are the
  demo-facing deliverables; no Dockerfile's instructions change, so the
  `example-dockerfile-smoke` matrix is unchanged.
- Language parity: no impact — no contract, manifest or runtime behaviour moves.
