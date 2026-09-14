---
id: FRIC-026
type: dogfood-finding
severity: medium
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Generated example mints duplicate charge IDs (`Random.int` without `Random.self_init`)

**Description:** The scaffolded HTTP handler generates the charge/event id with `Printf.sprintf "ch_%06d" (Random.int 999999)` (`cli/sol/lib/sol_cli_scaffold_templates.ml:685`). `Random` is never seeded, so it produces a fixed sequence per process start. Observed live: the first `POST /charges` in workspace 1 returned `ch_770445`, and the first POST in a *different* workspace returned `ch_770445` again. The id is used as the `Charged` event's `id` and as the default correlation id.

**Impact:** The reference application teaches a pattern where event ids collide across restarts and across deployments. In the dogfood flow it makes "did the worker process *this* event?" ambiguous, and anyone copying the scaffold's id strategy into real code inherits non-unique ids on the wire.

**Remediation:** Seed the generator (`Random.self_init ()` at startup) or, better for a reference app, derive the id from a real source (DB sequence, UUID) so the example demonstrates a correct idempotency key. Update the scaffold template, the checked-in `examples/pluto` equivalents, and any test that pins the `ch_%06d` format.

Related: FEAT-069/FEAT-070 (release/deployment identity), the repo's own emphasis on deterministic, non-colliding identities.
