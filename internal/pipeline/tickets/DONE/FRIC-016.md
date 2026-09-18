---
id: FRIC-016
type: dogfood-finding
severity: high
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Building the CLI from source is undocumented: OCaml ≥ 5.4, `opam update`, `dune` in the new switch, and 11 external `*-eio` packages

**Description:** `README.md` / `docs/dogfood/DOGFOOD.md` say `eval $(opam env) && dune build`, but a fresh machine cannot follow that:
- `dune-project` requires `ocaml >= 5.4.0`; the only switch was 5.1.1.
- The opam index was stale enough that `opam show ocaml.5.4.1` returned "No package matching" until `opam update`.
- A newly created 5.4.1 switch has no `dune`.
- `sol.opam` depends on 11 external packages: `kafka-eio`, `obs-eio`, `obs-loki-eio`, `obs-prometheus-eio`, `obs-tempo-eio`, `pg-eio`, `aws-eio`, `s3-eio`, `dynamodb-eio`, `lambda-eio`, `https-eio`. Six are **not on opam** and must be pinned from GitHub. Only `.claude/CLAUDE.md` (agent-facing, and itself predicated on `~/Code/*` checkouts that a fresh machine won't have) explains this.

Working sequence, for reference: `opam update` → `opam switch create 5.4.1` → `opam install dune` → `opam pin add <pkg> https://github.com/loganbnielsen/<pkg>.git` for each of the 11 → `opam install --deps-only --with-test <sol>`.

**Impact:** No new contributor can build from source by following the user-facing docs; the first failure is an opaque `Library "X" not found`. This is a precondition for every other dogfood step.

**Remediation:** Add a "Build from source" section to `README.md` and `DOGFOOD.md` with the full sequence and the OCaml/dune requirements (including `opam update`); publish or pin the six missing packages so they resolve without per-package manual work; ideally provide a single `sol dev bootstrap`-style command or a documented script.

Related: the scaffolded workspace's own `README.md` already names `librdkafka-dev libpq-dev libpq5`, so the generated-artifact guidance is ahead of the top-level docs here.

## Completion notes

- Added a "Building from source (contributors)" section to `README.md` and a "Building the CLI from source" section to `docs/dogfood/DOGFOOD.md`, both with the verified sequence: `opam update`, `opam switch create 5.4.1`, `opam install dune`, pin the eleven external `*-eio` packages from GitHub, `opam install --deps-only --with-test .`, then `dune build cli/sol/bin/main.exe`.
- Doc-only change; no generated/manifest surface, so no example/demo update applies.
