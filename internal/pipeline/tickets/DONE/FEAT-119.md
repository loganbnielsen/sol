---
id: FEAT-119
type: feature
severity: medium
title: Project and reconcile the Sol event contract from @sol-fab/kafka
source: "BUG-105 (schema registration is a deployment step); DEC-022 TypeScript-parity tracking"
---

**Depends on:** None.

**Related:** BUG-105 (the OCaml mechanism this mirrors), FEAT-118 (the retry/DLQ alignment), FEAT-080 (the capability matrix), DEC-022.

## Problem

BUG-105 moved schema registration out of the runtime and into the deployment lifecycle for OCaml applications. A workspace generates `contract/contract.exe`, which projects each event module's contract metadata as a language-neutral JSON object (`--json`) and validates and registers it against the target registry (`--check` / `--apply`). `sol up` runs the reconciliation locally; `sol deploy` runs it inside the destination on the deployment's own image; producer and consumer runtimes are read-only against the registry.

The published TypeScript packages still register schemas at runtime. `@sol-fab/kafka` writes to the schema registry when a producer or consumer starts, so a TypeScript application both retains the defect BUG-105 removed for OCaml and cannot participate in Sol's contract reconciliation — it has no projection for `sol plan` to inspect or `sol deploy` to reconcile.

Per DEC-022, parity is capability and behavioural, not implementation: a TypeScript application must expose the same contract — a projection of the same shape, produced from the same single source of truth (the message's schema declaration), consumed by the same deployment stages — while keeping the Node ecosystem underneath.

## Remediation

The `@sol-fab` packages live in their own repositories, outside this one. Bring them to the BUG-105 contract:

- Remove runtime registry mutation from `@sol-fab/kafka`: producer and consumer startup must read the registry only, and fail with a clear error when the contract is not registered.
- Expose the application's compiled event-contract metadata as the same language-neutral projection object BUG-105 defines (`{"version":1,"events":[{"module","topic","partitions","schema"}]}`), emitted by a generated entry point rather than hand-maintained.
- Accept a reconciliation mode equivalent to `--apply` (validate compatibility, then register) and a read-only check equivalent to `--check`, so Sol's deployment stages can drive it without change.
- Update `examples/pluto/app/demo_ts` to the projection, and refresh the per-capability verdicts in `internal/pipeline/dogfood/2026-09-07_typescript_demo_spike.md` (FEAT-080).

## Acceptance criteria

- `@sol-fab/kafka` never writes to the schema registry from a producer or consumer at runtime; an unregistered contract fails at startup.
- A TypeScript workspace can emit BUG-105's projection object, and `--check` / `--apply` behave as the OCaml projection does (idempotent apply, `FULL` compatibility set before registering).
- The projection is produced from a single declared source of truth, with no schema duplicated into `sol.toml` or another manifest.
- `examples/pluto/app/demo_ts` demonstrates the contract and its projection.
- FEAT-080's capability matrix records the aligned verdict.

**Demo/example coverage:** this ticket *is* the TypeScript example update.

## Design (2026-10-02): what a framework must expose

The unresolved question was *how Sol obtains a workspace's projection* without the CLI
knowing a language's build. The answer is a single, language-neutral entry point at a fixed
path, with a fixed protocol:

- **The workspace exposes `contract/run`**, an executable the framework provides. Sol drafts
  `sh ./contract/run <--json|--check|--apply> --scope <scope>` from the workspace root with
  `SCHEMA_REGISTRY_URL` set — no `dune`, `npm` or `gradle` in the CLI. An OCaml workspace's
  `contract/run` is one line (`exec dune exec ./contract/contract.exe -- "$@"`); a
  TypeScript workspace's runs its projection program; a Spring workspace's will run its
  Gradle task. `--json` prints the object BUG-105 defines (one line, stdout); `--check` is
  read-only; `--apply` sets `FULL` then registers; a non-zero exit is failure.
- **The scope is passed**, so a mixed workspace (pluto has OCaml events and the TS demo)
  can select the projection a scope needs without Sol knowing which is which. The
  projection is a workspace property, so units sharing a language share one implementation.
- **Every application image installs the same program at `/usr/local/bin/contract`**, the
  path `sol deploy`'s in-destination Job already runs. One Job per language in scope is
  submitted.
- **`has_projection` is file-presence on `contract/run`**, replacing the `scope_has_ocaml`
  language gate: a scope's ability to reconcile is now a property of the workspace, not of
  the languages in it.

The existing OCaml behavior is unchanged behind the entry point; the object format and the
`--json`/`--check`/`--apply` protocol are byte-compatible, so Sol consumes both languages
through one code path.

## Done (2026-10-02)

**`@sol-fab/kafka` 0.5.1** (`loganbnielsen/sol-kafka` PR #8, #10; tag `v0.5.1`, OIDC
trusted publish with provenance):

- `provisionTopic` / `resolveContract` / `connectTopic` are the read-only runtime: provision
  the topic, check reader compatibility, resolve the registered schema id, and fail when the
  declared contract is not registered. Replaces the runtime `registerTopic`, which
  registered *before* setting compatibility and swallowed the compatibility failure.
- `registerContract` is the only write path (set `FULL`, then register; both fatal);
  `checkCompatibility` now treats only the registry's 40401/40402 as "not registered yet".
- `contractProjection` emits BUG-105's object and `runContractCli` implements
  `--json`/`--check`/`--apply` with the OCaml program's exact modes and output.
- Tests: 60 cases, 60 pass (including the broker-backed multi-partition integration case,
  which now registers through `registerContract` and connects read-only through
  `connectTopic`). A snapshot test asserts the runtime issues no version `POST` and no
  compatibility `PUT`.

**Sol** (`cli`, examples, docs):

- `Sol_cli_contract` runs `sh ./contract/run <mode> --scope <scope>`; `has_projection` is
  `contract/run`; `reconciliation_images` returns one image per language in scope; the
  `scope_has_ocaml`/`declares_ocaml` language gates are gone from `sol up`, `sol deploy` and
  `sol plan`. `sol local run` now reconciles the scope's contract before it starts a unit,
  which the read-only runtime requires.
- Scaffold, `examples/pluto` and `internal/fixtures/venus` each gained `contract/run`;
  pluto's dispatches on scope.
- `examples/pluto/app/demo_ts` gained `@demo-ts/contract` (the single declared source of
  truth for `OrderPlaced`; `order_svc` imports it). Its `main.ts` is the projection program;
  both images install `/usr/local/bin/contract`.
- Docs: `internal/specs/framework-conventions.md`, `kafka-eio-service.md`, `CHANGELOG.md`,
  the demo README, and the capability matrix (`2026-10-02_cross_language_contract_audit.md`
  row 6 → implemented, § 4.3 resolved).

**Qualification.** Against the local broker + schema registry: `sh ./contract/run --apply
--scope demo_ts` registered `OrderPlaced` (schema id 3) and `--check` reported it
compatible; the demo built (`npm run build`) with the JSON object matching the OCaml shape;
the `order_svc` image built and its `/usr/local/bin/contract --json` emitted the same
object in-container. `golden-path-smoke-ts` (`sol up --scope=demo_ts` on a real k3d cluster)
is the end-to-end gate.

**Checks run.** `@sol-fab/kafka`: `tsc` clean, 60/60 tests. Sol: `dune build cli/bin/main.exe`
clean; `dune build @ci-unit` — the two pre-existing scaffold-compile cases fail only because
this switch lacks the extracted framework packages (`sol-obs`/`kafka-eio-service` not
installed; CI installs them), everything else green; demo `npm run build` clean; the contract
Job render test updated and passing. `check_no_comments` covers none of the new `contract/run`
files (extensionless) or the workflow edit; `pipeline validate` runs in CI.

**Demo/example coverage.** This ticket *is* the TypeScript example update, and the two
golden paths are the regression guard.

**Language parity.** Closes the schema-registry row of the capability matrix: both languages
register only from the deployment lifecycle, both runtimes read only, and both emit the same
projection object from a `contract/run` entry point. `@sol-fab/obs`/`@sol-fab/worker` are
unaffected.

**Limitations recorded, not blocking.**

- A mixed workspace's `contract/run` must dispatch on scope itself (pluto's does); Sol
  deliberately does not learn which language a scope needs.
- `sol local run` now needs the workspace's own toolchain (Node for the TS demo) because the
  projection runs from source; the TypeScript golden-path job gained `setup-node` + `npm ci`
  for exactly that.
- `-fn`, auth, peer calls and `@sol-fab/worker`'s `on_ready` remain the matrix's other rows
  (deferred or owned elsewhere).
