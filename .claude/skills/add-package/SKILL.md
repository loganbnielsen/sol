---
description: Use when adding a new library or package to the sol monorepo. Do not create package directory structures, dune files, or design docs manually without following this skill.
---

# /add-package — Add a new Sol package

Use this when adding a new library to the sol monorepo (e.g. `http`, `dynamo`, `lambda`).

## Steps

1. Create the directory structure:
```
sol/
  <name>/
    lib/
      <module>.ml
      <module>.mli
      dune
    test/
      test_<name>.ml
      dune
```

2. Write the `dune` file (use `(wrapped false)` for consistency with the rest of sol):
```
(library
 (name <name>)
 (wrapped false)
 (modules <Module>)
 (libraries <deps>))
```

3. Write the design document `<name>.md` in the package directory (e.g. `<name>/<name>.md`), following the pattern of `kafka-eio-service/kafka-eio-service.md`:
   - Overview
   - Package Structure
   - Public API (with typed signatures)
   - Configuration
   - Example Usage
   - Out of Scope (v1)

4. Update `README.md` status table to show the new package as "Design in progress" or "Implementation in progress".

5. Write Alcotest unit tests in `test/`. Integration tests go in the same directory and should check `KAFKA_BROKERS` or equivalent env vars before connecting to external systems.

## Conventions

- All public APIs return `(_, Error_type.t) result`. No exceptions.
- Configuration types are plain OCaml records with typed fields.
- All FFI is isolated in a `_raw.ml` module and never exposed publicly.
- Eio integration: take `sw:Eio.Switch.t` for any operation that spawns background fibers.
