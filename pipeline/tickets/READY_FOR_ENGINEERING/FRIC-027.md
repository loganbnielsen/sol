---
id: FRIC-027
type: dogfood-finding
severity: low
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Generated Dockerfiles reference the internal `~/Code/CLAUDE.md`

**Description:** Both generated service Dockerfiles carry a comment block explaining the opam pins that says "…are extracted opam packages (see `~/Code/CLAUDE.md`'s repo layout notes)". `~/Code/CLAUDE.md` is an author-local contributor document; it doesn't exist for a user, and its presence in generated code exposes internal process to the product surface. Template source: `cli/sol/lib/sol_cli_scaffold_templates.ml` (the `tpl_dockerfile` comment block).

**Impact:** Low, but it's a dead/confusing reference in the one artifact every user will read (their new service's Dockerfile), and it hints that generated output still leaks the maintainer's machine layout.

**Remediation:** Replace the path reference with a self-contained explanation (or a public docs link) of why those packages are pinned; keep the valuable "observed: https-eio needing tls-eio >= 2.1.0" rationale, drop the local path.

Related: FRIC-014 (Dockerfile template drift / example sync).
