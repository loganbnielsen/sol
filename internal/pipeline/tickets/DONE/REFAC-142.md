---
id: REFAC-142
type: refactor
severity: low
title: Remove comments from shell, Terraform and TypeScript, as the OCaml removal did
source: comment removal (2026-09-27), which covered OCaml only
---

**Depends on:** None.

The OCaml tree has no comments and `check_no_comments.sh` holds it. The same rule applies to the rest of the code, which is still comment-heavy (measured at the comment-removal PR's base, lines whose first non-blank token is a comment marker):

| Language | Files | Comment bytes | Total bytes |
|---|---|---|---|
| Shell (`*.sh`) | 107 | ~240 KB | 667 KB |
| Terraform (`*.tf`) | 25 | ~101 KB | 242 KB |
| TypeScript (`*.ts`) | 8 | ~9 KB | 27 KB |

## Remediation

Remove them with a lexer that respects each language: shell heredocs and `#` inside strings, `#!` lines and `# shellcheck` directives; Terraform heredocs and strings; TypeScript strings, template literals and regexes. Verify that the comment-stripped code is unchanged, then extend `check_no_comments.sh` to each language. What a guard script's header explained belongs in its failure message.

## Acceptance criteria

- No comments in those languages beyond tool directives (`#!`, `# shellcheck`), held by the guard, with a mutation test.
- CI green. Demo/example: examples and templates are included. Language parity: not applicable.

## Completion notes

**Premise verified (2026-09-27):** on `main` at `4e977407`, the real parsers found 4,607 comment lines across the shell, Terraform and TypeScript files.

**Removed, by each language's own parser:**

| Language | Files | Comments found by | Normal form compared, before and after |
|---|---|---|---|
| Shell (111 checked, including the two extensionless hooks) | 103 changed | `mvdan.cc/sh` (shfmt's parser) | shfmt's minified print, which drops comments and prints heredoc bodies verbatim |
| Terraform (`*.tf`, `*.tfvars`; 27 checked) | 22 changed | HashiCorp's `hclsyntax` lexer | the token stream without comments |
| TypeScript | 8 changed | the TypeScript compiler's comment ranges | the compiler's `removeComments` print |

Every file's normal form is identical before and after, so nothing but comments changed. The removal helpers were throwaway and are not committed. Tool directives stay: `#!`, `# shellcheck`, `// @ts-…`, `/// <reference>`. The first attempt collapsed blank lines inside a Python heredoc; the heredoc-verbatim comparison caught it, and blank lines are now collapsed only where a comment was removed. `terraform fmt` re-aligned four files where removing a comment merged two alignment groups.

**Mechanisms that were comments, now code:**
- `check_destroy_completeness.sh` required a `# residue:` comment on a resource that relinquishes deletion (DEC-045). Now the provider's residue code declares what it covers: `Sol_cli_gcp_destruction.relinquished_residue_probes` pairs the Terraform address with its probe, the sweep runs the list, and the guard requires every relinquishing resource's address to be in it. A positive control (renaming the registered address) fails the real tree, and the mutation test has a registered and an unregistered case.
- `check_kubernetes_object_ownership.sh` accepted a `# same-object-owner:` comment as an exception to "one Kubernetes object, one Terraform owner". No real Terraform used it, so the exception is gone. A future exception would be an explicit entry in the guard.
- `check_production_infra.sh` matched Terraform attribute text with single spaces. It now normalises whitespace, since `terraform fmt` alignment is not semantics.

**The guard:** `check_no_comments.sh` (with `internal/ci/no_comments.py`) now covers shell (through `shfmt --to-json`), Terraform and TypeScript as well as OCaml. Validated against the parsers on `main`: identical findings, zero misses and zero extras across 4,607 lines, and zero on this branch. The mutation test has 24 cases. CI installs a pinned `shfmt` v3.12.0 before the check.

**Not covered here:** comments in YAML (the CI workflows, Helm values), dune files, Dockerfiles, the two `.tftpl` templates (Alloy config and JSON), and Python embedded in shell heredocs, which the shell parser rightly treats as data.

**Demo/example:** the TypeScript demo and the example scripts are included; nothing an author writes changes. **Language parity:** not applicable.
