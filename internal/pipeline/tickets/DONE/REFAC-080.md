---
id: REFAC-080
type: refactor
severity: low
source: user session discussion 2026-09-09/10
---

**Depends on:** None. **Sequencing note:** do this only after all in-flight PRs and active worktrees are merged/closed. It is a repo-wide reformat and will conflict with almost every open branch.

Switch the repo's `ocamlformat` profile from `default` to `janestreet`.

## Problem

The repo currently uses `profile = default`:

- root `.ocamlformat`: `profile = default`, `version = 0.29.0`
- `examples/pluto/.ocamlformat`: same

We want the Jane Street house style. `ocamlformat.0.29.0` supports `profile = janestreet`, but switching rewrites essentially every OCaml file, so it needs to be a deliberate repo-wide change rather than mixed into feature tickets.

## Remediation

- Set `profile = janestreet` in the root `.ocamlformat`.
- Set `profile = janestreet` in `examples/pluto/.ocamlformat` too, so formatting is consistent across the repo.
- Run `dune fmt` once and commit the whole reformat.
- Update `.claude/CLAUDE.md`'s formatter note if it mentions the profile or formatting expectations.

## Review process

This is deliberately a **mechanical, deterministic change** and does not need the usual separate review agent:

- the only intentional edit is the `.ocamlformat` profile lines;
- every other diff is formatter output;
- the verification is mechanical: `dune fmt --preview` clean, `dune build @all` green, and the existing test suite green.

The PR should state that explicitly so the `soldev pipeline review` step can be a fast deterministic pass rather than a subagent review.

## Acceptance criteria

- Root and `examples/pluto` `.ocamlformat` both use `profile = janestreet`.
- `dune fmt --preview` reports no changes.
- `dune build @all` and the test suite pass.
- The diff contains no semantic edits beyond the profile change and formatter output.
- The PR description records the deterministic verification instead of a review-agent verdict.
