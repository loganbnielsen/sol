# Sol scaffold audit — 2026-09-16

**Scope:** executable scaffold checks only; no infrastructure dogfood.

| Step | Result |
|---|---|
| fresh `sol new workspace audit_workspace` | PASS, 30 files |
| initial `dune build` | PASS |
| add svc, worker, fn, and event | PASS |
| final `dune build` | PASS |

The generated OCaml surface remains clean: domain/event ownership is visible,
all primitives compile, Dockerfiles are non-root, and no hand-written Kubernetes
manifests are generated. TypeScript generation is still absent, but that premise
is already captured precisely by `pipeline/tickets/BACKLOG/FEAT-084.md`; no
duplicate scaffold finding was filed.
