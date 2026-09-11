---
id: AUDIT-038
type: audit-finding
severity: medium
branch: AUDIT-037/dockerfile-opam-deps
worktree: /home/lbendtly/Code/sun-AUDIT-037-dockerfile-opam-deps
source: 2026-06-12h_audit.md
branch: AUDIT-037/dockerfile-opam-deps
worktree: /home/lbendtly/Code/sun-AUDIT-037-dockerfile-opam-deps
---

# AUDIT-038 — `tpl_github_deploy` uses stale `ocaml/setup-ocaml@v2` and imprecise OCaml version pin

**Depends on:** None.

## Description

In `cli/sun/lib/sun_cli_cmd_new.ml`, two CI workflow templates are emitted to every new workspace:

- `tpl_github_ci` → `.github/workflows/sun-ci.yml` — correctly uses `ocaml/setup-ocaml@v3` and `ocaml-compiler: "5.4.1"` (lines 184, 186, 210, 212, 278, 280).
- `tpl_github_deploy` → `.github/workflows/deploy.yml` — uses `ocaml/setup-ocaml@v2` and `ocaml-compiler: "5.4"` (lines 357, 359).

`ocaml/setup-ocaml@v2` is the superseded version of the action. `"5.4"` is an imprecise version pin that may resolve to a different patch release than `"5.4.1"`, causing a build environment mismatch between the two workflows in the same repository.

## Impact

A workspace owner relying on the generated deploy workflow may see CI inconsistencies or build failures when the two workflows compile with different OCaml versions. This erodes trust in Sun's generated CI setup without an obvious explanation.

## Remediation

In `cli/sun/lib/sun_cli_cmd_new.ml`, update `tpl_github_deploy` (around line 357):

```yaml
      - uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false
```

Match exactly the values used in `tpl_github_ci`.

## Review — automated checks passed
tpl_dockerfile gains ptime+otoml; tpl_github_deploy upgraded to setup-ocaml@v3 and ocaml-compiler 5.4.1; build and tests clean
