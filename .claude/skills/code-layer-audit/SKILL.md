---
description: Audit code architecture by checking abstraction layers, dependency direction, file/module boundaries, and shared-code placement. Use when reviewing whether a codebase is organized at the right level of abstraction, especially Sol and the ~/Code/*-eio packages.
---

# /code-layer-audit - Abstraction and File Boundary Audit

Review architecture by tracing real code paths, not by enforcing a fixed number
of layers. A boundary is good only when it owns a real translation, policy, or
state boundary.

Use a cross-cutting mindset. Prefer one boundary-level fix over local patches in
many callers. If the clean design requires a public API break in Sol or the
foundation packages under the user's control, recommend the break plainly
instead of preserving a bad API shape for compatibility.

Default scope for Sol work:

- `/home/lbendtly/Code/sol`
- `/home/lbendtly/Code/*-eio` when the request mentions shared foundation,
  integrations, observability, package extraction, or cross-package shape.

## What To Map

For each important feature path, identify the actual layers:

- Public API: what application/user code calls.
- Neutral model: provider-independent records, events, commands, or errors.
- Adapter: translation into one provider, protocol, framework, or external package.
- Runtime/transport: HTTP, DB, filesystem, subprocesses, queues, clocks,
  switches, locks, or platform wiring.
- Helpers: flat local helpers. Treat them as a layer only when shared by
  multiple real callers.

Do not reward depth. Fewer layers are better when the code stays readable and
the dependency direction is clean.

## Findings

Flag these first:

- Provider/framework concepts leaking into the public API.
- Public API convenience leaking into adapters or transport.
- Core/domain modules doing provider formatting or wire protocol work.
- Adapters making product policy decisions that belong above them.
- Shared helpers that only have one caller.
- A common module that mixes unrelated helpers because they are "utilities".
- Thin wrapper files that only delegate.
- Files named by implementation detail when callers need a domain concept.
- Files named by domain concept when they mostly contain protocol/runtime code.
- Cross-package imports that point the wrong way.
- Duplicate helpers across packages that should either stay duplicated because
  they are tiny, or move down because two adapters truly need the same thing.
- Compatibility shims, aliases, or optional parameters that keep a broken layer
  shape alive after the intended API is clear.

## File Organization

Prefer the boring layout that makes ownership obvious:

- Put the public surface in one small module/file when possible.
- Keep provider adapters in provider-named files.
- Keep transport helpers below adapters, never imported by the public API unless
  transport is the API.
- Keep validation near the boundary that receives untrusted or caller-supplied input.
- Keep encoding/formatting next to the protocol it targets.
- Split a file when it has two reasons to change, not when it is merely long.
- Share code only after the second real use. Until then, private local helper.
- If sharing code creates a new package dependency, require a meaningful line
  deletion or consistency win; otherwise duplicate the tiny helper.
- Break callers together when moving a boundary. Do not leave old and new
  pathways side by side unless there is a real released-user migration need.

## Output

Lead with the ranked findings. One line per finding when possible:

`<tag> <location>: <problem>. <replacement>.`

Useful tags:

- `leak:` boundary leak
- `yagni:` abstraction/shared code with no real second use
- `split:` file has unrelated reasons to change
- `merge:` boundary/file only delegates
- `move:` code belongs in another layer/package
- `duplicate:` repeated code should be shared, or deliberately left duplicated
- `name:` module/file name hides the layer it actually implements

End with the simplest recommended architecture in one short code-path sketch,
for example:

`app -> public API -> neutral event -> provider adapter -> transport helper`

If the current shape is already lean, say so and list only residual risks.

For a full audit of Sol, also write
`pipeline/audits/<YYYY-MM-DD>_code_layer_audit.md`. If actionable findings are
open and `pipeline/tickets/READY_FOR_ENGINEERING/` exists, materialize tickets
as `CODE_LAYER-NNN`, continuing from the highest existing `CODE_LAYER-*` ID
across `pipeline/audits/` and `pipeline/tickets/`. Do not create ticket
directories in standalone packages just to satisfy this format.
