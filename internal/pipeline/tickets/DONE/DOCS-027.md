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

## Completion notes (2026-09-30)

`docs/guides/application-authoring.md` is published, and `docs/README.md` marks it so.

**A reader can design a domain and add each primitive from the page alone** (AC1). The page
gives the decision rule first (a caller waits → `-svc`; something happened → `-worker`; time
passed → `-fn`), then one section per primitive with the entry-point shape and the generated
layout, then the task recipes: add a domain and a unit, add an event, add a table, add a
scheduled function, wire a dependency, add a service dependency. The workspace section states
the layout, the `sol.yml` declaration, and the rule that a unit's directory and its declaration
must agree (`sol check` fails when they do not).

**Both language paths are stated, with the gaps recorded** (AC2). Parity is stated the way
DEC-022 defines it — capability and behavioural parity, not implementation parity — and the two
current gaps are named rather than glossed: the `sol new --language typescript` entry point does
not exist (FEAT-084; `sol new svc|worker|fn` scaffolds OCaml, and a TypeScript unit is written
in the same shape as the OCaml one, as `examples/pluto/app/demo_ts` does), and the production
profile's preflight still refuses a TypeScript workload (DEC-026 §2; the standing goal is
FEAT-102 and the state is in `docs/deployment/compatibility.md`). The TypeScript demos are
pointed at as the worked `-svc` and `-worker` examples.

**No signature is restated** (AC3). The page links `docs/reference/runtime.md` (health, config
injection, discovery, migration filenames, synchronous calls), the application contract index,
and the five package specs, and quotes code only where the *shape* is the point.

**Every sample is real** (AC4). Each code block is taken from a cited path:
`app/checkout/checkout_svc/bin/main.ml` and `app/comms/notify_worker/bin/main.ml` for the two
primitives, `events/payments/charged.ml` for the event contract, `sol.yml`'s declaration, and
`app/<domain>/<name>_{svc,worker,fn}/` for the generated layout — verified against
`cli/lib/workspace/sol_cli_cmd_new.ml` (`component_suffix`) and
`platform/shared/templates/event/events/{{team}}/{{name}}.ml`, whose shape the quoted event
matches. The `-fn` walkthrough is the tutorial's, and the anchor was corrected to the heading
that exists (`#new-scheduled-function`).

**Demo/example coverage:** the samples in this page *are* the examples — each is a path in
`examples/pluto` or the tutorial — so the ticket adds no new runnable example of its own. One
gap is recorded rather than invented away: `examples/pluto` has no `-fn` unit, so the scheduled
function is documented from the tutorial's walkthrough and the scaffold template.

**Language parity:** this page is where the parity statement is made for authors; it adds no
capability, so no new per-language verdict is owed, and the two documented gaps already carry
tickets (FEAT-084, FEAT-102).
