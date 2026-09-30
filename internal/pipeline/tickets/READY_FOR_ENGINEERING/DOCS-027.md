---
id: DOCS-027
type: documentation
severity: medium
title: Write the application authoring guide for a Sol workspace
source: docs/README.md documentation roadmap (2026-09-29)
---

**Depends on:** None.

**Related:** `docs/reference/README.md`, `docs/reference/runtime.md`,
`docs/guides/TUTORIAL.md` (the tutorial's existing application-model sections),
`framework/ocaml/*/` package specs, `FEAT-084` (TypeScript unit scaffolding),
`DEC-022` (OCaml/TypeScript parity), `examples/pluto`.

## What this page is

The user-facing guide to building an application on Sol: how a workspace is
organised, what the three primitives are for, how units communicate, and how the
same model holds in both application languages. It is the conceptual companion to
the contract (`docs/reference/`) and to the per-package OCaml specs in
`framework/`.

Today the material is scattered: the README's application-model section, the
tutorial's scaffold/extend sections, and the framework package specs, which are
written for maintainers of each package rather than for an app author choosing
between primitives.

## Audience

An application developer who has finished installation and wants to design and
grow a workspace: add a domain, choose between `-svc`/`-worker`/`-fn`, define an
event, add a migration, and know which language path to take.

## Outline

1. **The workspace** — domains, units, the `app/<domain>/<name>_{svc,worker,fn}/`
   layout, and where events and migrations live.
2. **The three primitives** — `-svc`, `-worker`, `-fn`, and the decision rule for
   each, including the "a function is `run : unit -> result`, the trigger is
   configuration" framing.
3. **Events as the only cross-domain contract** — typed events, the schema
   registry, and why teams do not share code across domains.
4. **Choice of language** — OCaml and TypeScript as first-class, what parity means
   (`DEC-022`), the current TypeScript scaffolding gap (`FEAT-084`), and how to
   pick.
5. **The ordinary operations an author performs** — add an event, add a unit, add
   a table/migration, add a scheduled function, wire a service dependency.
6. **Where the contract lives** — link `docs/reference/runtime.md` and the package
   specs rather than restating signatures.

## Sources of truth to link, not copy

- Runtime expectations: `docs/reference/runtime.md`.
- The application contract index: `docs/reference/README.md`.
- Kernel/API detail: the co-located package specs under `framework/ocaml/`.
- Runnable proof: `examples/pluto` (OCaml) and `examples/pluto/app/demo_ts`
  (TypeScript).

## Acceptance criteria

- A reader can design a new domain and add each primitive from the page alone,
  without reading `AGENTS.md` or a package spec.
- The OCaml and TypeScript paths are both stated, with parity and its current gaps
  recorded honestly.
- No declaration or signature is duplicated from a package spec or `.mli`; the
  page links to the authority.
- Every code sample is exercised by `examples/pluto` or the tutorial.
- `docs/README.md` marks this page Published.

## Notes

- Do not turn this into an API reference; that is the package specs and the
  contract pages. This page is the conceptual and task-level guide.
- If a section needs a framework primitive that does not exist, file it rather
  than documenting an aspiration as if it worked.
