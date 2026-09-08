---
id: AUDIT-036
type: audit-finding
severity: medium
source: project/audits/2026-06-12g_audit.md
branch: AUDIT-036/tls-deps-dune-project
worktree: ../sun-AUDIT-036-tls-deps-dune-project
---

Add TLS package dependencies to Sun `dune-project`

**Depends on:** None.

**Description:** The Sun `dune-project` declares `(generate_opam_files true)` and lists package dependencies in `(package (name sun) (depends ...))`. After AUDIT-029 added `tls-eio`, `x509`, `domain-name`, and `ptime` as library dependencies of `kafka-eio-service`, these packages were not added to the `(package ... (depends ...))` stanza. The generated `sun.opam` file is therefore incomplete.

**Impact:** Installing Sun from source via `opam install . --deps-only` fails to install the TLS libraries. Running `dune build` after that yields `Error: Library "x509" not found`. Any CI workflow that uses `opam install . --deps-only` (including future Sun monorepo CI) will break.

**Remediation:** Add `tls-eio`, `x509`, `domain-name`, and `ptime` to the `(depends ...)` stanza in `dune-project`:
```
tls-eio
x509
domain-name
ptime
```
Then run `dune build` to regenerate `sun.opam` and verify `opam install . --deps-only` installs all required packages cleanly.
