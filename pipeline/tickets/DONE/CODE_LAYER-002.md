---
id: CODE_LAYER-002
type: code-layer-finding
severity: medium
source: project/audits/2026-09-05_code_layer_audit.md
---

DynamoDB table layer is missing an object representation step

**Problem:** `Dynamodb_table.Index` gives typed key/index access, but reads
still return raw `Dynamodb_client.item`. `Entity.stamp` and `Entity.check`
provide discriminator safety, but they are separate helpers callers must
remember to compose before decoding a domain value.

**Goal:** Add a small object representation layer that owns
domain-value-to-DynamoDB-item encoding, DynamoDB-item-to-domain-value decoding,
and entity discriminator stamping/checking. Keep typed index access separate so
repositories compose the pieces explicitly.

**Target shape:**

```text
app repository
  -> Dynamodb_table.Index + Dynamodb_table.Object
  -> Dynamodb_client
  -> Aws.Http
```

**Design guidance:**

- Keep `Dynamodb_table.Index` focused on typed partition/sort key formatting
  and index selection. It may continue returning raw item/page values.
- Add an object/domain representation functor, for example
  `Dynamodb_table.Object`, with a caller-supplied object type plus
  `encode`/`decode`.
- The object layer should automatically stamp the reserved entity
  discriminator on encode and check it before decode.
- Do not make `Index` depend on a specific object type yet. A single index can
  legitimately contain multiple entity/object types, and repositories are the
  right place to choose which object decoder applies to a given query.
- Do not add a repository framework. App code can compose `Index.get` with
  `Object.decode_option`, and `Index.query_all` with `Object.decode_list`.
- Keep this inside `dynamodb-eio` for now. A separate ElectroDB-like package is
  only justified once the object/repository layer grows enough to need its own
  release boundary or multiple abstraction styles over the same raw client.

**Acceptance criteria:**

- `Dynamodb_table` exposes a public object representation abstraction whose
  encode path stamps the entity discriminator.
- The decode path checks the entity discriminator before running the
  caller-supplied decoder, so callers cannot accidentally decode the wrong
  entity shape through this layer.
- Helper functions cover the common result shapes:
  `decode`, `decode_option`, `decode_list`, and page mapping if `query_page`
  remains a first-class public result.
- README and `.mli` describe `Index` as typed key/index access, and describe
  the object layer as the domain encode/decode boundary.
- Package metadata stops describing `dynamodb-eio` as if the existing
  `Index` helper is already the full ElectroDB replacement; it should describe
  the composable raw client, typed index, and object representation layers.
- Existing `Entity.stamp`/`Entity.check` either become internal implementation
  details of the object layer or remain documented as lower-level escape
  hatches, but the main path should not require manual composition.
- Focused `dynamodb-eio` tests cover the chosen boundary.

## Resolution

Implemented and merged upstream in `~/Code/dynamodb-eio` (external
opam-pinned package): commit `770f16f` / "Add Dynamodb_table.Object:
domain encode/decode with entity discrimination" (#17). sun's own PR #113
recorded the ticket closure but carried no sun-tree diff. sun's opam pin
points at a ticket-specific worktree/branch
(`~/Code/dynamodb-eio-CODE_LAYER-002#CODE_LAYER-002/dynamodb-table-object`)
rather than dynamodb-eio's main — verified byte-identical (`git diff` empty)
to dynamodb-eio's current main tip, so functionally current; re-pinning to
the canonical repo/main is cosmetic cleanup, not a correctness fix.
