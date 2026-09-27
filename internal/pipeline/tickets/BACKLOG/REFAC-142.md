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
