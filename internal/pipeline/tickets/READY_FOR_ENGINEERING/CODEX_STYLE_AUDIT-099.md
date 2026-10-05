---
id: CODEX_STYLE_AUDIT-099
type: bug
severity: medium
title: "Distinguish absent TypeScript build metadata from invalid existing metadata"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Distinguish absent TypeScript build metadata from invalid existing metadata

**Depends on:** None.

**Principles:** 1, 7, 19, 21–23, 31, 32, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/local/sol_cli_local_run.ml:114`: ancestor package.json errors are ignored while inferring npm workspace ownership.
- `:133`: every tsconfig read/parse failure chooses dist.
- `:185`: inferred ownership controls build cwd/package selection and launch artifact.
- workspaces_of/string_list also filter invalid metadata shapes into empty declarations.

## Mechanism and impact

Malformed existing metadata creates a successful recipe with a guessed layout. A workspace package can become a standalone npm build, and a broken tsconfig becomes a nonexistent launch path. The eventual process error obscures the original invalid input.

## Remediation

Return explicit absence/read/parse outcomes for optional metadata. Retain documented defaults for actual omission, refuse invalid existing metadata with path context, and validate the field shapes used to select workspace ownership and output paths.

## Acceptance criteria

- Absent optional tsconfig keeps its documented default.
- Malformed/unreadable existing tsconfig refuses recipe planning.
- Invalid ancestor package metadata cannot silently change build ownership.
- Valid workspace and standalone layouts retain correct cwd/argv/artifact.
- Cover malformed workspaces/main/outDir fields according to their supported contract.

- Demo/example: exercise the runnable TS reference workspace and a standalone unit fixture.
- Language parity: explicit TS capability verdict; OCaml recipe behavior stays equivalent to its existing contract.

## Existing work and scope

DEC-023 discusses workspace inference, not this error suppression. The local supervisor ticket owns process execution after a valid recipe; this one owns recipe inputs.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
