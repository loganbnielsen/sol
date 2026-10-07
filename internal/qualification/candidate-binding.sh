#!/usr/bin/env bash
# Bind the application and framework artifacts a live qualification exercises to
# the exact immutable candidate revision it gathers evidence for.
#
# An installed release names the revision it was built from
# (`share/sol/<version>/REVISION`, written by build-release-bundle.sh). A live run
# must build the application under test from that revision:
#
#   * the workspace must be that revision's tree, with no modified tracked file;
#   * every pin that fetches the Sol framework must name that commit, never a
#     moving ref such as `main`.
#
# Otherwise a stale checkout -- or a `main` that advanced after the candidate was
# cut -- can substitute another revision's framework or application code while the
# run reports evidence bound to this candidate. Every check fails closed; nothing
# is built when a check refuses (sol-fab/sol#1280).

sol_candidate_die() {
  printf 'candidate-binding: %s\n' "$1" >&2
}

sol_candidate_is_revision() {
  case "${1:-}" in
    "" | *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# sol_candidate_bind_context <workspace> <revision> <out>
#
# Materialize a Docker build context at <out> holding the tracked files of
# <workspace> at <revision>, with every `github.com/sol-fab/sol.git#<ref>` pin
# rewritten to `#<revision>`. Prints one line per framework pin it bound, for the
# run's evidence. Refuses, changing nothing, when the workspace is not that
# revision's unmodified tree or when the framework cannot be shown to come from it.
sol_candidate_bind_context() {
  local source="${1:-}" revision="${2:-}" out="${3:-}"
  if [ -z "$source" ] || [ -z "$out" ]; then
    sol_candidate_die "usage: sol_candidate_bind_context <workspace> <revision> <out>"
    return 1
  fi
  if [ ! -d "$source" ]; then
    sol_candidate_die "no workspace at '$source' to bind to the candidate"
    return 1
  fi
  if ! sol_candidate_is_revision "$revision"; then
    sol_candidate_die "the release names revision '$revision', which is not a 40-hex commit"
    return 1
  fi
  local head
  if ! head="$(git -C "$source" rev-parse HEAD 2>/dev/null)"; then
    sol_candidate_die "'$source' is not a git work tree, so it cannot be shown to be the candidate revision $revision"
    return 1
  fi
  if [ "$head" != "$revision" ]; then
    sol_candidate_die "the workspace is at $head but the candidate is $revision; building it would qualify another revision's application as this candidate's"
    return 1
  fi
  if [ -n "$(git -C "$source" status --porcelain --untracked-files=no)" ]; then
    sol_candidate_die "'$source' has modified tracked files, so its tree is not revision $revision"
    return 1
  fi

  rm -rf "$out"
  mkdir -p "$out"
  if ! git -C "$source" ls-files -z | (cd "$source" && xargs -0 cp --parents -t "$out"); then
    sol_candidate_die "could not materialize revision $revision's tracked files from $source"
    return 1
  fi

  local file
  while IFS= read -r -d '' file; do
    sed -i -E "s|(github\.com/sol-fab/sol\.git)#[^\"[:space:]]+|\1#$revision|g" "$file"
  done < <(find "$out" -type f -name '*.opam' -print0)

  local refs stale="" count=0 ref
  refs="$(grep -rIho 'github\.com/sol-fab/sol\.git#[^"[:space:]]*' "$out" 2>/dev/null || true)"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    count=$((count + 1))
    if [ "$ref" != "github.com/sol-fab/sol.git#$revision" ]; then
      stale="$ref"
    fi
  done <<<"$refs"
  if [ -n "$stale" ]; then
    sol_candidate_die "the build context still fetches the Sol framework from $stale, not from the candidate revision $revision"
    return 1
  fi
  if [ "$count" -eq 0 ]; then
    sol_candidate_die "the build context pins no Sol framework revision, so the framework it builds against cannot be shown to be the candidate's"
    return 1
  fi
  printf '%s\n' "$refs"
}

# sol_candidate_record_binding <dir> <revision> <workspace> <context>
#
# Write the binding the run actually enforced beside its other evidence.
sol_candidate_record_binding() {
  local dir="${1:-}" revision="${2:-}" workspace="${3:-}" context="${4:-}"
  local pins="${5:-}"
  mkdir -p "$dir"
  {
    printf 'candidate_revision: %s\n' "$revision"
    printf 'workspace: %s\n' "$workspace"
    printf 'build_context: %s\n' "$context"
    printf 'framework_pins:\n'
    if [ -n "$pins" ]; then printf '%s\n' "$pins" | sed 's/^/  /'; fi
  } >"$dir/candidate-binding.txt"
}
