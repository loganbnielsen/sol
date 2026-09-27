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

## Completion notes

**Premise re-verified (2026-09-27, `origin/main` `de55f187`).** The survey held:
13 dune files carrying 97 comment lines (the ticket's earlier count of 64 files
was files *named* `dune`, not files with comments), and 12 Dockerfiles carrying
180. Every commented Dockerfile is a scaffold, example or fixture file; none is
maintainer-only.

**What landed.**

- **`AGENTS.md`** gains a *Comments: none in covered formats* section beside the
  Documentation Protocol: the covered formats and their enforcement, tool
  directives as the one exception, invariants to types/shared definitions/guards/
  tests, durable rationale to the docs or the record that owns it, user-facing
  explanation to the documentation that ships with the artifact — plus the list of
  categories that are deliberately *not* covered, so nobody sweeps them
  opportunistically. This is the piece that would have saved a cycle: the rule was
  previously discoverable only by failing CI step 43.
- **dune files**: 97 comment lines across 13 files. The domain headers and the
  repeated DAG paragraph are in `AGENTS.md`'s repo layout and DONE/REFAC-104.md;
  `cli/test/dune`'s rule rationales are carried by the rules' own failure text and
  their tickets (INFRA-035/075/076/091, SEC-010, REFAC-115/117, FEAT-089/100);
  `dune-project`'s DEC-025 block is DONE/DEC-025.md's subject and is named in
  `AGENTS.md`; `platform/shared/templates/dune`'s `data_only_dirs` rationale is in
  DONE/REFAC-128.md and enforced by the build itself.
- **Dockerfiles**: 180 comment lines across 12 files, with the explanation moved
  into `platform/shared/templates/workspace/README.md` (a new Container images
  section, verified in a rendered scaffold with no template placeholder left),
  `examples/pluto/README.md`, `examples/pluto/app/demo_ts/README.md`, and
  `docs/guides/TUTORIAL.md`. `internal/fixtures/venus/**` simply loses its comments
  — an internal test fixture, with the same Dockerfiles' explanation now in the
  scaffold README.
- **The invariant that was a comment** is now a test:
  `cli/test/test_manifest_render.ml` renders every primitive and checks the
  template's `USER` against the manifest's `runAsUser`/`runAsGroup`.

**Deliberately left.** Two notes in `cli/test/dune` remain, and this is the one
place the sweep is incomplete on purpose: they explain why
`check_no_account_artifacts.sh` and `check_production_infra.sh` are *not* dune
rules. That reasoning belongs with those guards, which the CI and tooling work
owns, so writing it anywhere else would be a second copy and editing the guard
would overlap that ownership. They should move with the guard when it next
changes.

**Verification.** `dune build` and `dune fmt` clean; `check_ocamlformat.sh --all`
clean; the whole CLI suite (84 suites, 0 failures) including the scaffold goldens,
which compare the generated Dockerfile with its template, and the README test
that no `{{name}}` placeholder survives; every `internal/ci/check_*.sh` that runs
without extra inputs (`check_no_comments.sh` needs `shfmt`, absent on this machine,
so its OCaml half was run directly through `no_comments.py`: 427 files, none with
a comment; `check_readiness_invocations.sh` wants its invocations and says so).
The Dockerfile change is proven comment-only: for all 12 files the non-comment
lines are byte-identical to `origin/main`'s. `docker build` of
`app/demo_ts/order_svc` from the example workspace succeeds against the stripped
file, and an OCaml image build was left running as a second, slower check — CI's
`example-dockerfile-smoke` matrix is the authoritative one.

**Demo/example.** This ticket *is* the scaffold and example documentation, so
/demo-review applied. Run for real: `sol new workspace demoapp` from this build,
which ships the comment-free Dockerfile and the new README section (checked with
no unrendered placeholders). The two personas were then run as explicit passes
over the diff and that transcript rather than as independent subagents, because no
subagent tool is available in this session — so treat them as a self-review, not
as the independent reads the skill wants. The demo persona's questions are
answered by the run: the Dockerfiles build, CI's smoke jobs still cover the matrix
(no Dockerfile instruction changed), and the rationale is one section away in the
same directory. The client persona's: an app author reading the generated
Dockerfile now sees 15 lines of instructions and finds the glibc pin, the
dependency ownership, the `opam repository set-url` gotcha and the uid in their own
README; the one thing left is that a reader who opens *only* the Dockerfile gets no
signpost to it, which the policy rules out putting in a comment and which is not
worth a command-output change here.

**Deferred, as instructed:** CI/workflow YAML and embedded Python in CI guards (CI
and tooling ownership), user-facing scaffold/example/delivery YAML (a later
explicit product and documentation pass), `internal/qualification/**` (live-run
records), and the `.tftpl` templates (no semantic-equivalence check for rendered
River config).

**Language parity: no impact.** No contract, manifest or runtime behaviour moved;
the TypeScript Dockerfiles changed only in their comments, and their explanation
now sits in the demo's own README.

