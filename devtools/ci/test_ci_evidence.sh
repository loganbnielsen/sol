#!/usr/bin/env bash
# Tests for ci-evidence.sh.
#
# ci-evidence.sh decides whether the expensive CI suite may be skipped, so each
# condition that disqualifies an earlier run is pinned here in isolation. GitHub
# is replaced by a stub serving fixture JSON; merges and ancestry use real git.
#
# Run: bash devtools/ci/test_ci_evidence.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE="$HERE/ci-evidence.sh"
FAILURES=0
TOTAL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok() { TOTAL=$((TOTAL + 1)); printf '  [OK]   %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); printf '  [FAIL] %s\n' "$1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

# ── A repository shaped like a pull request that was updated from main ──────
REPO="$WORK/repo"
git init -q -b main "$REPO"
cd "$REPO" || exit 1
git config user.email t@example.com
git config user.name t
commit() { git add -A && git commit -q -m "$1" && git rev-parse HEAD; }
put() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1"; }

put app.txt base
put .github/workflows/ci.yml v0
put devtools/ci/gate.sh v0
M0="$(commit m0)"

git checkout -q -b feature
put app.txt feature
F1="$(commit f1)"

git checkout -q main
put other.txt main-moved
M1="$(commit m1)"

# The pull request is updated from main: its new head contains M1.
git checkout -q feature
git merge -q --no-edit main
F2="$(git rev-parse HEAD)"

# A second pull request edited the CI definition, which main later adopted.
git checkout -q -b ci-edit "$M0"
put .github/workflows/ci.yml v1
put app.txt ci-edit
FC="$(commit fc)"
git checkout -q main
put .github/workflows/ci.yml v1
M2="$(commit m2)"
git checkout -q ci-edit
git merge -q --no-edit main
FC2="$(git rev-parse HEAD)"

# A commit with M1's content that is not on main.
git checkout -q -b twin "$M0"
put other.txt main-moved
M1X="$(commit m1x)"

# A pull request that reverts main's CI change, and an earlier head without it.
git checkout -q -b revert "$M1"
put app.txt reverted
FR="$(commit fr)"
git checkout -q -b revert-2 "$M2"
put app.txt reverted
put .github/workflows/ci.yml v0
FR2="$(commit fr2)"

# A pull request that changes the CI definition itself.
git checkout -q -b ci-change "$M2"
put devtools/ci/gate.sh changed
FX="$(commit fx)"

git checkout -q --detach "$F2"

# ── Support-package commits and the GitHub stub ────────────────────────────
DEP_A="$(printf 'a%.0s' {1..40})"
DEP_B="$(printf 'b%.0s' {1..40})"
REFS="$WORK/refs"
printf 'kafka-eio %s\nhttps-eio %s\n' "$DEP_A" "$DEP_B" > "$REFS"

FIX="$WORK/fixtures"
mkdir -p "$FIX"
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = api ] || exit 1
[ -e "$FIX/fail" ] && exit 1
case "$2" in
  */actions/workflows/*/runs\?*) cat "$FIX/runs.json" ;;
  */actions/runs/*/jobs\?*) id="${2#*/runs/}"; cat "$FIX/jobs-${id%%/*}.json" ;;
  */actions/runs/*/artifacts\?*) id="${2#*/runs/}"; cat "$FIX/artifacts-${id%%/*}.json" ;;
  */actions/artifacts/*/zip) id="${2#*/artifacts/}"; cat "$FIX/artifact-${id%%/*}.zip" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/gh"
export FIX CI_EVIDENCE_GH="$WORK/gh"

# run <id> <head> <record-base> [refs-file] [classify-completed] [artifact-created] [record-head]
run() {
  local id="$1" head="$2" base="$3" refs="${4:-$REFS}"
  local done_at="${5:-2026-09-17T04:03:50Z}" made_at="${6:-2026-09-17T04:03:45Z}" rhead="${7:-$2}"
  printf '{"jobs":[{"name":"classify","completed_at":"%s"},{"name":"test","completed_at":"2026-09-17T04:10:00Z"}]}\n' "$done_at" > "$FIX/jobs-$id.json"
  printf '{"artifacts":[{"id":%s,"name":"ci-evidence","created_at":"%s","expired":false}]}\n' "$id" "$made_at" > "$FIX/artifacts-$id.json"
  {
    printf 'ci-evidence 1\nbase %s\nhead %s\n' "$base" "$rhead"
    awk 'NF == 2 { print "ref " $1 " " $2 }' "$refs"
  } > "$WORK/record"
  python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z: z.write(sys.argv[2], "ci-evidence.txt")' "$FIX/artifact-$id.zip" "$WORK/record"
}

# runs <id>:<head>[:<conclusion>]...
runs() {
  local entries=() spec id head conclusion
  for spec in "$@"; do
    IFS=: read -r id head conclusion <<< "$spec"
    entries+=("{\"id\":$id,\"head_sha\":\"$head\",\"conclusion\":\"${conclusion:-success}\"}")
  done
  local IFS=,
  printf '{"workflow_runs":[%s]}\n' "${entries[*]}" > "$FIX/runs.json"
}

find_run() {
  local base="$1" head="$2"
  shift 2
  timeout 20 "$EVIDENCE" find --repo o/r --workflow ci.yml --branch feature/x \
    --base-tip main --base "$base" --head "$head" --refs "$REFS" "$@" 2>/dev/null
}

reset() { rm -f "$FIX"/*; git checkout -q --detach "$F2"; }

echo "ci-evidence find: reuse"
reset
run 101 "$F1" "$M1"
runs 101:"$F1"
expect "a passing run that tested this exact code is reused" 101 "$(find_run "$M1" "$F2")"
expect "the current run never counts as its own evidence" "" "$(find_run "$M1" "$F2" --exclude-run 101)"

reset
run 102 "$F1" "$M0"
run 101 "$F1" "$M1"
runs 102:"$F1" 101:"$F1"
expect "a run against older main is skipped for a matching one" 101 "$(find_run "$M1" "$F2")"

echo "ci-evidence find: disqualified runs"
reset
run 102 "$F1" "$M0"
runs 102:"$F1"
expect "main changed code since that run" "" "$(find_run "$M1" "$F2")"

reset
printf 'kafka-eio %s\nhttps-eio %s\n' "$DEP_A" "$DEP_A" > "$WORK/other-refs"
run 101 "$F1" "$M1" "$WORK/other-refs"
runs 101:"$F1"
expect "different support-package commits" "" "$(find_run "$M1" "$F2")"

reset
run 101 "$F1" "$M1"
runs 101:"$F1":failure
expect "a run that did not succeed" "" "$(find_run "$M1" "$F2")"

reset
run 101 "$F1" "$M1" "$REFS" 2026-09-17T04:03:50Z 2026-09-17T04:09:00Z
runs 101:"$F1"
expect "evidence uploaded after classify finished" "" "$(find_run "$M1" "$F2")"

reset
run 101 "$F1" "$M1"
printf '{"artifacts":[{"id":101,"name":"ci-evidence","created_at":"2026-09-17T04:03:45Z","expired":false},{"id":102,"name":"ci-evidence","created_at":"2026-09-17T04:03:46Z","expired":false}]}\n' > "$FIX/artifacts-101.json"
runs 101:"$F1"
expect "more than one evidence artifact" "" "$(find_run "$M1" "$F2")"

reset
run 101 "$F1" "$M1" "$REFS" 2026-09-17T04:03:50Z 2026-09-17T04:03:45Z "$F2"
runs 101:"$F1"
expect "a record naming a different head" "" "$(find_run "$M1" "$F2")"

reset
run 101 "$F1" "$M1X"
runs 101:"$F1"
expect "a recorded base that is not on the base branch" "" "$(find_run "$M1" "$F2")"


reset
run 101 "$F1" "$M1"
printf 'not a zip' > "$FIX/artifact-101.zip"
runs 101:"$F1"
expect "an unreadable artifact" "" "$(find_run "$M1" "$F2")"

reset
git checkout -q --detach "$FC2"
run 103 "$FC" "$M2"
runs 103:"$FC"
expect "a run whose head edited the CI definition" "" "$(find_run "$M2" "$FC2")"

echo "ci-evidence find: this run is not eligible"
reset
git checkout -q --detach "$FR2"
run 104 "$FR" "$M1"
runs 104:"$FR"
expect "this change edits the CI definition, even back to an old version" "" "$(find_run "$M2" "$FR2")"

reset
git checkout -q --detach "$F1"
run 101 "$F1" "$M0"
runs 101:"$F1"
expect "git's merge does not reproduce the checked-out tree" "" "$(find_run "$M1" "$F2")"

reset
: > "$WORK/empty-refs"
run 101 "$F1" "$M1" "$WORK/empty-refs"
runs 101:"$F1"
expect "support-package commits unresolved" "" "$(timeout 20 "$EVIDENCE" find --repo o/r --workflow ci.yml --branch feature/x --base-tip main --base "$M1" --head "$F2" --refs "$WORK/empty-refs" 2>/dev/null)"

reset
run 101 "$F1" "$M1"
runs 101:"$F1"
touch "$FIX/fail"
out="$(find_run "$M1" "$F2")"
status=$?
expect "GitHub unavailable prints nothing" "" "$out"
expect "GitHub unavailable still exits 0" 0 "$status"

out="$(timeout 20 "$EVIDENCE" find --repo 2>/dev/null)"
status=$?
expect "a flag without a value terminates and prints nothing" "0:" "$status:$out"

echo "ci-evidence record"
reset
expect "records base, head and sorted commits" \
  "$(printf 'ci-evidence 1\nbase %s\nhead %s\nref https-eio %s\nref kafka-eio %s' "$M1" "$F2" "$DEP_B" "$DEP_A")" \
  "$("$EVIDENCE" record --base "$M1" --head "$F2" --refs "$REFS" 2>/dev/null)"
"$EVIDENCE" record --base "$M2" --head "$F2" --refs "$REFS" > /dev/null 2>&1
expect "refuses a base that does not reproduce the tested tree" 1 "$?"

echo "ci-evidence resolve"
DEP_REPO="$WORK/dep"
git init -q -b main "$DEP_REPO"
git -C "$DEP_REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m dep
DEP_SHA="$(git -C "$DEP_REPO" rev-parse HEAD)"
printf '# comment\n\nfoo-eio file://%s\n' "$DEP_REPO" > "$WORK/packages"
expect "resolves each package's main" "foo-eio $DEP_SHA" \
  "$(CI_EVIDENCE_PACKAGES="$WORK/packages" "$EVIDENCE" resolve 2>/dev/null)"
printf 'foo-eio file://%s\nbar-eio file://%s/missing\n' "$DEP_REPO" "$WORK" > "$WORK/packages"
CI_EVIDENCE_PACKAGES="$WORK/packages" "$EVIDENCE" resolve > /dev/null 2>&1
expect "fails when any package cannot be resolved" 1 "$?"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ci-evidence: all $TOTAL checks passed"
else
  echo "ci-evidence: $FAILURES of $TOTAL checks FAILED"
  exit 1
fi
