---
id: CODEX_STYLE_AUDIT-089
type: bug
severity: medium
title: "Send service request failures through configured structured observability"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Send service request failures through configured structured observability

**Depends on:** None.

**Principles:** 18, 20, 22, 24, 30–32, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `framework/ocaml/sol-svc/lib/service.ml:168`: handler exceptions print directly to stderr.
- `:183`: respond_or_500 does the same for outer request failures.
- `:419`: the production controller dispatches while owning an optional Sol_obs observer, but no error reporter reaches these branches.
- `:475`: transport on_error likewise writes raw stderr.

## Mechanism and impact

HTTP 500 responses and request metrics survive, but original exception details bypass the configured Loki/backend and lose structured service/operation context. Raw stderr collection may exist in some deployments; it does not provide the framework's configured structured diagnostic contract.

## Remediation

Pass a named request-error reporter or return a typed dispatch diagnostic to the controller. The production owner should report through Sol_obs when configured, with a deliberate fallback otherwise. Keep generic client-facing 500s, stable route metadata, and cancellation/fatal exception propagation.

## Acceptance criteria

- Configured observer receives exactly one structured diagnostic for handler, outer dispatch, and transport failures.
- Cause and stable operation/route fields remain available; client response stays generic.
- No credentials/body leakage, raw-path metric cardinality, duplicate logging, or swallowed cancellation.
- Failure-injection tests cover configured observer and explicit fallback.

- Demo/example: add or update a runnable service example showing configured failure diagnostics.
- Language parity: inspect the TS service error handler, which also uses console.error, and record equivalent behavior or a concrete follow-up.

## Existing work and scope

BUG-053 covers counted 500s and AUDIT-025 covers decode logging; neither owns these diagnostic sinks. Avoid broad logging API redesign.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
