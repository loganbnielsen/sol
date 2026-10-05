# Sol maintainer context

Sol is a pre-alpha software factory for backend systems. The `sol` CLI and platform
are language-neutral; OCaml and TypeScript applications target the same application
and deployment contract.

## Repository map

- `cli/` — the `sol` CLI and typed deployment/lifecycle implementation.
- `framework/` — first-party application framework packages.
- `platform/` — Terraform, Helm values, templates, and other assets driven by Sol.
- `examples/` — runnable reference applications.
- `docs/` — user guidance, reference, and durable architecture.
- `internal/ci/` — executable repository/product guards.
- `internal/qualification/` — live behavioral claims, procedures, and evidence.
- `internal/fixtures/` — test fixtures.

Read the authority nearest the thing you are changing. Do not copy subsystem rules
into this file.

## Development posture

Sol is pre-alpha. There are no compatibility guarantees for current APIs or repository
structure: prefer the correct design over compatibility shims, deprecated aliases, or
version gates. Update callers and tests in the same change.

GitHub Issues and pull requests are the work-state authority. Use ordinary Git branches
or worktrees; their names carry no Sol-specific semantics. Open focused PRs, rely on
required CI, request review proportional to risk, and squash-merge. Do not recreate
repository-local workflow state with labels, bots, branch conventions, or custom tooling.

## Build and validation

Set up the pinned support packages and dependencies as described in the README, then:

```sh
eval "$(opam env)"
dune build
```

Run the smallest relevant tests while developing. Before proposing a change, run the
cheap repository checks:

```sh
bash internal/ci/run_fast_checks.sh
```

Required GitHub CI is authoritative for merge. Live cloud qualification is separate from
ordinary development; follow `internal/qualification/README.md` when a claim requires it.

## Durable invariants

- Sol owns only its declared contract boundary. Users may integrate arbitrary
  infrastructure against that boundary; Sol neither plans nor manages it.
- Destructive lifecycle decisions fail closed on unknown state. Absence must be
  positively established, and live qualification independently verifies absence.
- The declarative Sol contract is canonical for application/deployment intent; generated
  language bindings and artifacts are projections, not competing authorities.
- Production Kafka uses authenticated, encrypted transport; local development may use
  deliberate plaintext configuration. Do not infer that local and production settings
  must be identical.
- Generated artifacts are outputs. Change their typed/source owner rather than patching
  generated YAML or other projections as the primary implementation.
- Preserve OCaml/TypeScript behavioral contract parity without requiring implementation
  parity.
- Security ambiguity, destructive live actions, and architectural decisions require
  explicit operator judgment. Ordinary implementation work should proceed autonomously.

## Documentation ownership

- `README.md` — product entry point and source-build path.
- `docs/reference/` — current application/CLI contract.
- `docs/guides/` — task-oriented user guidance.
- `docs/architecture/` — current architecture and durable ADRs.
- package-local docs — package-specific public/maintainer contracts.
- `internal/qualification/` — qualification claims, procedures, and evidence.

## Simplicity budget

Repository-wide process or tooling must protect a concrete guarantee that Git, GitHub, or existing
CI does not already provide. Prefer a simpler design or a test at the failure boundary over turning
an incident into a permanent global rule. Historical state belongs in Git and pull requests unless
it is a current product, architecture, or qualification authority.

History belongs in Git and pull requests, not current instructions. If prose conflicts
with executable behavior, verify the implementation and fix or remove the stale prose
rather than adding another authority.
