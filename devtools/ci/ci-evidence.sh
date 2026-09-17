#!/usr/bin/env bash
# ci-evidence.sh -- reuse a passing CI run for byte-identical tested code.
#
# A pull request's checks rerun for every new head, even when the code under
# test is identical to a run that already passed -- typically after branch
# protection forces an up-to-date merge from main. The classify job uses this
# script to skip the expensive suite in exactly that case.
#
# Subcommands:
#   resolve
#       Print "<package> <commit>" for every support package in packages.txt,
#       at the commit its main branch points to now. Exits non-zero if any
#       package cannot be resolved.
#   record --base SHA --head SHA --refs FILE
#       Print the evidence record a full run uploads as its `ci-evidence`
#       artifact. Refuses unless git's merge of base and head reproduces the
#       checked-out tree, so a record's base is the base actually tested.
#   find --repo OWNER/NAME --workflow FILE --branch NAME --base-tip REV
#        --base SHA --head SHA --refs FILE [--exclude-run ID]
#       Print the id of an earlier run whose evidence covers the code this run
#       tests, or nothing.
#
# `find` FAILS CLOSED: any error, missing datum or mismatch prints nothing and
# the full suite runs. An earlier run counts only when every check below holds,
# each made against GitHub's records or local git rather than the record alone:
#   1. this change leaves the CI definition (.github/, devtools/ci/) untouched,
#      so the check itself is main's rather than the pull request's;
#   2. git's merge of this base and head reproduces the tree GitHub is testing
#      (HEAD), so merge trees are comparable at all;
#   3. GitHub reports the earlier run succeeded;
#   4. the earlier head's own changes leave the CI definition untouched, so that
#      run executed a CI definition from main, which records honestly;
#   5. its one `ci-evidence` artifact was created before its classify job
#      completed -- by classify, before any job ran pull-request code;
#   6. the record names that run's real head, and a base on the base branch;
#   7. merging the recorded base and head reproduces this run's tree;
#   8. it pinned the same support-package commits this run resolved.
# Drift outside those inputs (third-party opam packages, runner images) is not
# covered, just as it is not when an old commit is re-run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES="${CI_EVIDENCE_PACKAGES:-$HERE/../../.github/actions/pin-opam-packages/packages.txt}"
GH="${CI_EVIDENCE_GH:-gh}"
CI_PATHS=(.github devtools/ci)
ARTIFACT=ci-evidence

log() { printf 'ci-evidence: %s\n' "$*" >&2; }

usage() { sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

resolve() {
  local pkg url sha found=0
  while read -r -u 3 pkg url; do
    case "$pkg" in '' | '#'*) continue ;; esac
    sha="$(git ls-remote "$url" refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }')"
    if ! is_sha "$sha"; then
      log "cannot resolve main of $pkg ($url)"
      return 1
    fi
    printf '%s %s\n' "$pkg" "$sha"
    found=1
  done 3< "$PACKAGES"
  [ "$found" = 1 ]
}

refs_lines() { awk 'NF == 2 { print "ref " $1 " " $2 }' "$1" | LC_ALL=C sort; }

record() {
  if [ "$(merged_tree "$BASE" "$HEAD_SHA")" != "$(git rev-parse 'HEAD^{tree}' 2>/dev/null)" ]; then
    log "git's merge of base and head does not reproduce the tested tree"
    return 1
  fi
  printf 'ci-evidence 1\nbase %s\nhead %s\n' "$BASE" "$HEAD_SHA"
  refs_lines "$REFS"
}

# True when the range changes the CI definition -- or cannot be diffed at all.
touches_ci() {
  local out
  out="$(git diff --name-only "$1" "$2" -- "${CI_PATHS[@]}" 2>/dev/null)" || return 0
  [ -n "$out" ]
}

# The tree of a clean merge, or nothing: a conflicted merge still prints a tree.
merged_tree() {
  local out
  out="$(git merge-tree --write-tree "$1" "$2" 2>/dev/null)" || return 0
  printf '%s\n' "$out" | head -n 1
}

have_commit() {
  git cat-file -e "$1^{commit}" 2>/dev/null \
    || git fetch --quiet --no-tags origin "$1" 2>/dev/null
}

# Echo the id of the run if it is reusable evidence for TREE, else nothing.
check_run() {
  local id="$1" head="$2" tmp="$3"
  local classify_done artifacts aid created rbase rhead mb

  classify_done="$("$GH" api "repos/$REPO/actions/runs/$id/jobs?per_page=100" 2>/dev/null \
    | jq -r '[.jobs[] | select(.name == "classify") | .completed_at] | if length == 1 then .[0] // "" else "" end' 2>/dev/null)"
  [ -n "$classify_done" ] || { log "run $id: no single completed classify job"; return; }

  artifacts="$("$GH" api "repos/$REPO/actions/runs/$id/artifacts?per_page=100" 2>/dev/null \
    | jq -r --arg n "$ARTIFACT" '[.artifacts[] | select(.name == $n)] | if length == 1 and (.[0].expired | not) then "\(.[0].id) \(.[0].created_at)" else "" end' 2>/dev/null)"
  [ -n "$artifacts" ] || { log "run $id: no single live $ARTIFACT artifact"; return; }
  read -r aid created <<< "$artifacts"
  if [[ "$created" > "$classify_done" ]]; then
    log "run $id: evidence created after classify finished"
    return
  fi

  "$GH" api "repos/$REPO/actions/artifacts/$aid/zip" > "$tmp/evidence.zip" 2>/dev/null || return
  unzip -p "$tmp/evidence.zip" "$ARTIFACT.txt" > "$tmp/record" 2>/dev/null || return
  [ "$(head -n 1 "$tmp/record")" = "ci-evidence 1" ] || { log "run $id: unknown record format"; return; }
  rbase="$(awk '$1 == "base" { print $2 }' "$tmp/record")"
  rhead="$(awk '$1 == "head" { print $2 }' "$tmp/record")"
  if [ "$rhead" != "$head" ] || ! is_sha "$rbase"; then
    log "run $id: record does not describe the run's head"
    return
  fi

  have_commit "$head" && have_commit "$rbase" || { log "run $id: commits unavailable"; return; }
  mb="$(git merge-base "$head" "$BASE_TIP" 2>/dev/null)" || return
  if touches_ci "$mb" "$head"; then
    log "run $id: its head changed the CI definition"
    return
  fi
  git merge-base --is-ancestor "$rbase" "$BASE_TIP" 2>/dev/null \
    || { log "run $id: recorded base is not on the base branch"; return; }
  [ "$(merged_tree "$rbase" "$head")" = "$TREE" ] \
    || { log "run $id: tested different code"; return; }
  [ "$(grep '^ref ' "$tmp/record" | LC_ALL=C sort)" = "$(refs_lines "$REFS")" ] \
    || { log "run $id: pinned different support-package commits"; return; }

  printf '%s\n' "$id"
}

find_evidence() {
  local tmp runs id head branch_q found mb
  [ -s "$REFS" ] || { log "support-package commits unresolved"; return 0; }
  mb="$(git merge-base "$BASE" "$HEAD_SHA" 2>/dev/null)" || { log "no merge base for this change"; return 0; }
  if touches_ci "$mb" "$HEAD_SHA"; then
    log "this change touches the CI definition; running the full suite"
    return 0
  fi
  TREE="$(git rev-parse 'HEAD^{tree}' 2>/dev/null)" || return 0
  if [ "$(merged_tree "$BASE" "$HEAD_SHA")" != "$TREE" ]; then
    log "git's merge does not reproduce the tested tree"
    return 0
  fi

  branch_q="$(jq -rn --arg b "$BRANCH" '$b | @uri')" || return 0
  runs="$("$GH" api "repos/$REPO/actions/workflows/$WORKFLOW/runs?event=pull_request&status=success&branch=$branch_q&per_page=20" 2>/dev/null \
    | jq -r '.workflow_runs[] | select(.conclusion == "success") | "\(.id) \(.head_sha)"' 2>/dev/null)" || return 0

  tmp="$(mktemp -d)"
  while read -r id head; do
    [ -n "$id" ] && [ "$id" != "$EXCLUDE" ] || continue
    found="$(check_run "$id" "$head" "$tmp")"
    if [ -n "$found" ]; then
      rm -rf "$tmp"
      printf '%s\n' "$found"
      return 0
    fi
  done <<< "$runs"
  rm -rf "$tmp"
  return 0
}

cmd="${1:-}"
shift || true
REPO="" WORKFLOW="" BRANCH="" BASE_TIP="" BASE="" HEAD_SHA="" REFS="" EXCLUDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}" ;;
    --workflow) WORKFLOW="${2:-}" ;;
    --branch) BRANCH="${2:-}" ;;
    --base-tip) BASE_TIP="${2:-}" ;;
    --base) BASE="${2:-}" ;;
    --head) HEAD_SHA="${2:-}" ;;
    --refs) REFS="${2:-}" ;;
    --exclude-run) EXCLUDE="${2:-}" ;;
    *) log "unknown argument: $1"; exit 2 ;;
  esac
  shift $(($# > 1 ? 2 : 1))
done

case "$cmd" in
  resolve) resolve ;;
  record)
    is_sha "$BASE" && is_sha "$HEAD_SHA" && [ -s "$REFS" ] || { log "record needs --base, --head and --refs"; exit 2; }
    record
    ;;
  find)
    for v in REPO WORKFLOW BRANCH BASE_TIP BASE HEAD_SHA REFS; do
      [ -n "${!v}" ] || { log "find is missing a value for $v"; exit 0; }
    done
    find_evidence
    ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
