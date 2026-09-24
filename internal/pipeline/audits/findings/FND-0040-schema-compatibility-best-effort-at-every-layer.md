# FND-0040 — The schema-compatibility guarantee is best-effort at every layer

- **Classification:** `DESIGN_GAP`
- **State:** `OPEN`
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `BUG-049`
- **Evidence class:** `STATIC`

## Three sources that disagree

- `kafka-eio-service.md` "Out of Scope (v1)": *"Schema evolution / compatibility
  enforcement (add `compatibility` setting to schema registry)"*.
- The code **does** attempt it: `set_subject_compatibility` PUTs `{"compatibility":"FULL"}`
  (`kafka_service_schema.ml:82-98`).
- The tutorial and scaffold present `Schema.check_all` as the CI gate that *"blocks the
  schema change before it reaches staging"* (`docs/guides/TUTORIAL.md:492`).

## Where each layer degrades silently

1. **FULL is set after registering, and a failure only warns.** `register`
   (`kafka_service.ml:256-277`) registers the schema first, then sets FULL, and on error
   prints `warn: could not set schema compatibility …` and continues. A subject whose
   PUT ever failed stays at the registry default (BACKWARD on Redpanda/Confluent), and
   every later registration and `check` is evaluated against that weaker level with no
   further signal.
2. **Any 404 counts as "no version registered".** `Schema.check`
   (`kafka_service_schema.ml:66`) returns `Ok ()` on HTTP 404 without reading the body.
   The registry uses 404 for subject-not-found (40401) and version-not-found (40402), but
   a wrong base URL or proxy path also returns 404. A misconfigured gate therefore passes
   every schema.
3. **The generated gate passes when it cannot run.** `test/test_schemas.ml`
   (`sol_cli_scaffold_templates.ml:992-1015`) prints a skip line and **exits 0** when
   `SCHEMA_REGISTRY_URL` is unset, so CI is green without checking. Its message list
   (`[ (module Charged) ]`) is hand-written, so a new `MESSAGE` added later is unchecked
   unless someone edits the list.

## Impact

Medium. Consumers rely on evolution safety that is either off by the spec's own account,
or on only when a warn-only PUT happened to succeed, and is verified by a gate that
passes when absent or misconfigured.

## Decision needed

State the contract: is FULL enforced? If yes: set compatibility **before** registering
and fail `register` on error; treat 404 as "absent" only for error code 40401; make the
scaffold gate fail (not skip) in CI when the registry is absent, and derive its message
list from the events packages. If no: remove the PUT and the "gate" language.

## Related

FEAT-037 (protocol/policy split in `kafka-eio-service`); FEAT-034 (TS port: registration
order was wrong twice there). DEC-022 parity unassessed.
