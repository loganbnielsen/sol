#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ci_dir="${VERIFY_CI_DIR:-$root/internal/ci}"
class="${1:-}"

members=()

class_dir() {
  case "$1" in
    always) printf '%s/always\n' "$ci_dir" ;;
    static) printf '%s\n' "$ci_dir" ;;
    *) return 1 ;;
  esac
}

discover() {
  local dir="$1" path
  [ -d "$dir" ] || return 1
  members=()
  while IFS= read -r path; do
    members+=("$path")
  done < <(find "$dir" -maxdepth 1 -type f \( -name 'check_*' -o -name 'test_*' \) | LC_ALL=C sort)
  [ "${#members[@]}" -gt 0 ]
}

run_member() {
  local index="$1" path="$2"
  local started=$SECONDS
  case "$path" in
    *.py) python3 "$path" >"$results/$index.out" 2>&1 ;;
    *) bash "$path" >"$results/$index.out" 2>&1 ;;
  esac
  printf '%s %s\n' "$?" "$((SECONDS - started))" >"$results/$index.status"
}

report() {
  local results="$1"
  local -a failed=()
  local index code seconds label
  for index in "${!members[@]}"; do
    label="${members[$index]#"$root/"}"
    if [ ! -f "$results/$index.status" ]; then
      printf 'FAIL    no-result  %s\n' "$label"
      failed+=("$index")
      continue
    fi
    code=""
    read -r code seconds <"$results/$index.status" || code=""
    case "$code" in
      '' | *[!0-9]*) code=1 ;;
    esac
    if [ "$code" -eq 0 ]; then
      printf 'PASS %5ss  %s\n' "${seconds:-?}" "$label"
    else
      printf 'FAIL %5ss  %s\n' "${seconds:-?}" "$label"
      failed+=("$index")
    fi
  done
  for index in "${failed[@]}"; do
    [ -f "$results/$index.out" ] || continue
    printf '\n──── FAIL: %s\n' "${members[$index]#"$root/"}"
    cat "$results/$index.out"
  done
  printf '\nverify %s: %s/%s members failed\n' "$class" "${#failed[@]}" "${#members[@]}"
  [ "${#failed[@]}" -eq 0 ]
}

main() {
  local dir
  if ! dir="$(class_dir "$class")"; then
    printf 'verify: unknown verification class %s\n' "${class:-<none>}" >&2
    printf 'verify: known classes: always static\n' >&2
    return 2
  fi
  if ! discover "$dir"; then
    if [ ! -d "$dir" ]; then
      printf 'verify: class %s has no directory at %s\n' "$class" "$dir" >&2
    else
      printf 'verify: class %s has no members in %s; a check of nothing is not a pass\n' "$class" "$dir" >&2
    fi
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || {
    printf 'verify: class %s requires python3, which is not on PATH\n' "$class" >&2
    return 1
  }
  source "$root/internal/ci/lib/scratch_repo.sh"
  scratch_repo_sanitize
  results="$(mktemp -d)"
  trap 'rm -rf "$results"' EXIT
  local started=$SECONDS parallelism index
  parallelism="$(nproc 2>/dev/null || echo 4)"
  printf 'verify %s: running %s members, %s at a time\n' "$class" "${#members[@]}" "$parallelism"
  for index in "${!members[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$parallelism" ]; do
      wait -n
    done
    run_member "$index" "${members[$index]}" &
  done
  wait
  report "$results"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cd "$root" || exit 1
  main "$@"
fi
