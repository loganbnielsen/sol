# Sol docs and API-contract audit — 2026-09-16

**Scope:** README, tutorial, roadmap, example READMEs, package specs, and public
OCaml interfaces. Dogfood procedures were not run.

## Findings

### DOCS-016 — First-class TypeScript story is inconsistent across primary docs

* **Severity:** Medium
* **Locations:** `README.md`, `docs/guides/TUTORIAL.md`,
  `docs/planning/ROADMAP.md`, `examples/pluto/app/demo_ts/README.md`
* **Description:** README leads with OCaml and TypeScript as first-class, but the
  tutorial still defines Sol as a platform for OCaml services and its local-run
  comparison assumes native OCaml binaries. The roadmap likewise defines the
  product as OCaml-only. README and the TypeScript demo say the TS layer consists
  of two packages (`kafka`, `obs`), while both runnable units now also consume
  published `@sol-fab/svc` and `@sol-fab/worker`.
* **Remediation:** make the product framing and capability/status table agree in
  all three primary docs; inventory all four published packages; link the mixed
  OCaml/TS Pluto example; clearly label the still-open scaffold and deployed-CI
  gaps as FEAT-084 and FEAT-087 instead of implying they already exist.

### DOCS-017 — Package specs no longer match public interfaces

* **Severity:** Medium
* **Locations:** `framework/kafka-eio-service/kafka-eio-service.md`,
  `framework/sol-svc/sol-svc.md`, corresponding `.mli` files
* **Description:** examples include `config_of_env : unit -> config` although it
  now returns `(config, error) result`; old flat `Kafka_error`/`Kafka_consumer`
  names instead of `Kafka.Error`/`Kafka.Consumer`; non-optional decode bytes;
  `Response.not_implemented`, which is not public; a request shape missing
  `trace_ctx`; and `Service.Make.run` returning `unit` while the interface
  returns `(unit, run_error) result` and supports `?stop`.
* **Remediation:** derive signature blocks directly from current `.mli` files,
  remove obsolete members, and add a small docs check that compiles extracted
  examples or at least diffs declared signature lines against the interfaces.

### DOCS-018 — Three reusable audit procedures still target the pre-rename product

* **Severity:** Medium
* **Locations:** `docs/audits/UX_AUDIT.md`, `STYLE_AUDIT.md`,
  `SCAFFOLD_AUDIT.md`, plus path inventory in `STYLE_AUDIT_FINDINGS.md`
* **Description:** these procedures still prescribe `sun` commands,
  `cli/sun`, `Sun.*` modules, removed hosted/control-plane code, and in the UX
  runbook even obsolete `sun dev`/`sun cloud init` command shapes. Following
  them literally cannot audit the current product.
* **Remediation:** update the reusable procedures to current `sol` commands,
  paths, modules, and product boundaries; delete checklist items for removed
  features rather than translating them mechanically.

## Passes

- README accurately marks Sol pre-production and links both language examples.
- Pluto's README visibly contains OCaml and TypeScript units in one workspace.
- The generated OCaml workspace README and source compile as written.
- Existing FEAT-084 (TS scaffolding) and FEAT-087 (deployed TS CI) already track
  real parity gaps; this audit did not duplicate them.
