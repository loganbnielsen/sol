---
id: CODE_LAYER-004
type: code-layer-finding
severity: medium
source: project/audits/2026-09-05_code_layer_audit.md
---

Obs trace model cannot represent parent span IDs

**Problem:** `Obs_eio.span_event` carries only the current trace context. `obs-tempo-eio` cannot set OTLP `parent_span_id`, so spans with the same trace ID are not connected as parent/child spans in Tempo.

**Goal:** Put parent span identity in the neutral obs model so trace adapters can render real waterfalls.

**Design guidance:**

- Add parent identity to `Obs_eio.span_event`, not to `Obs_trace.t`.
  `Obs_trace.t` should keep representing the propagated W3C trace context for
  the current span.
- Model this as `parent_span_id : int64 option` or an equivalent typed span-id
  field on the emitted span record.
- `Obs_eio.with_span ?parent` should derive the child/current span context as
  it does today, while also preserving `parent.span_id` on the emitted event.
- Do not route parentage through `Obs_eio.with_context` or a future
  `Sun_obs.set_context`; context is searchable metadata, while parent span ID
  is structural trace graph data.
- Break backend record construction loudly rather than hiding the field behind
  a compatibility shim. Each adapter should consciously map or ignore the new
  span-event field.

**Acceptance criteria:**

- `Obs_eio.span_event` carries parent span ID when a span is opened with a
  parent.
- `Obs_tempo` maps that field into OTLP `parent_span_id`.
- Loki/Prometheus behavior remains compatible or explicitly ignores the new
  field.
- Tests prove `with_context` fields remain metadata only and are not used to
  represent trace parentage.
- Focused tests pass in `obs-eio` and `obs-tempo-eio`.

## Resolution

Implemented and merged upstream in `~/Code/obs-eio` (external opam-pinned
package): commit `b425c55` / "Obs_eio.span_event carries parent_span_id
for trace-graph linkage" (#14). sun's own PR #114 recorded the ticket
closure but carried no sun-tree diff. sun's opam pin points at a
ticket-specific worktree/branch
(`~/Code/obs-eio-CODE_LAYER-004#CODE_LAYER-004/parent-span-id`) rather than
obs-eio's main — verified byte-identical (`git diff` empty) to obs-eio's
current main tip, so functionally current; re-pinning to the canonical
repo/main is cosmetic cleanup, not a correctness fix.
