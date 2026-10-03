---
id: FEAT-053
type: feature
severity: medium
source: DEC-019 (platform repository boundary) — the CLI half of build-time secret handling
---

**Depends on:** DEC-016.

Let a service declare which secrets its **build** needs, separately from the secrets it needs at **runtime**, and export those names in the machine-readable plan so a builder knows what to provide. The tool declares and validates; for a hosted build it never holds the values.

## Scope

- **Separate the two sets in `sol.toml`.** Build-time and runtime secrets arrive through the same channels today, and that is exactly how they get conflated — a build that can read runtime secrets is a build that can leak them.
- **Validate and fail closed.** An undeclared build-time secret, or a runtime secret referenced at build time, is an error rather than a silently empty value.
- **Export the names in `--emit-plan-to`**, so the platform — or any CI — knows what to supply without having to know this repository's conventions.
- **Names only, never values**, in anything the tool emits or logs.

## Out of scope

Injection, log redaction, and image-layer hygiene at build time — platform work in its own repository (DEC-019).

## Acceptance criteria

- `sol.toml` distinguishes build-time from runtime secrets, and the distinction survives into the deployment plan.
- An undeclared or mis-scoped secret fails validation, naming the service and the key.
- `--emit-plan-to` exports declared build-time secret *names*, and no secret value appears in any emitted output.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: no `build_time`/`runtime` secret split exists in `cli/lib/workspace/sol_cli_toml.ml`; `--emit-plan-to` still exists in `cmd_deploy.ml`.

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Completion notes (2026-10-03)

**Premise:** confirmed at `origin/main` `aecff578` before starting — no build-time/runtime
split existed in `Sol_cli_toml`, and `--emit-plan-to` is still wired through `cmd_deploy.ml`.

### What landed

- `[infra.env] build_secrets` is a new declaration alongside `[infra.env] secrets`.
  `Sol_cli_toml.t` carries `build_secret_keys`; the loader rejects a key listed in
  both sets and a malformed array, naming the file (which carries the service path).
- `sol check` validates the key format of both sets, naming the scope
  (`invalid runtime secret key` / `invalid build-time secret key`).
- `Service_spec.build_secret_keys` flows into `--emit-plan-to` as each service's
  `build_secret_keys` — names only. Build-time keys are never rendered into a
  workload: the runtime Secret path consumes `secret_keys` only, so a build key
  cannot reach the pod.
- `examples/pluto/app/payments/charge_svc/sol.toml` declares
  `BUILD_REGISTRY_TOKEN`; the scaffold template documents the field.
  `docs/reference/substrate.md` (§ Postgres Connection Secret) and
  `docs/guides/TUTORIAL.md` state the distinction and the plan export.

### Fail-closed, and its honest boundary

Sol *declares and exports*; it never holds or injects build values (DEC-019). The
mis-scoping error it can see and does reject is one key in both sets. "An undeclared
build-time secret" is the external builder's contract: the builder receives exactly
the exported names, and a build that needs a value not declared fails there. Sol does
not parse the Dockerfile for a secret reference it was never given; recorded rather
than worked around.

### Checks

`dune build @all` clean; `dune test cli/test` green (new: build-secret parse,
scope-conflict rejection, plan export, and both `sol check` key-format cases);
`internal/ci/run_fast_checks.sh` green (97 members, including the guard mutation
suites). `dune fmt` applied.

### Acceptance mapping

| Criterion | Evidence |
|---|---|
| `sol.toml` distinguishes build-time from runtime, survives into the plan | `build_secrets` parsed into `build_secret_keys`; `service_to_json` emits `build_secret_keys` beside `secret_keys` |
| An undeclared or mis-scoped secret fails validation, naming the service and the key | Scope conflict rejected in `Sol_cli_toml.load_result` naming the key and file; `sol check` names the scope for a malformed key |
| `--emit-plan-to` exports declared build-time secret *names*, and no value appears | `build_secret_keys` is a string-name list; no value is stored for build secrets anywhere |

**Demo/example coverage.** `examples/pluto` declares a build-time secret and the plan
exports it; the scaffold template documents the field and the tutorial shows the TOML.

**TypeScript parity (DEC-022).** No language-parity impact: this is a CLI/`sol.toml`
declaration and plan-emission change. `@sol-fab/*` neither consumes Sol's plan nor
declares build-time secrets.
