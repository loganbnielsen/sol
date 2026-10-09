#!/usr/bin/env bash
set -euo pipefail

sol="$1"

# cmdliner colors its errors when stderr is a terminal, so pin a dumb terminal: the
# assertions below match the message text, and a colored run would hide it.
export TERM=dumb
export NO_COLOR=1

# The user model is target-addressed, so there is no `sol cloud` group. `sol destroy` is
# top-level and keeps its destructive confirmation; the cloud-ownership audit is the
# target-scoped `sol target reconcile`.
destroy_help="$($sol destroy --help=plain)"
grep -Eq "^[[:space:]]+sol destroy" <<<"$destroy_help"
grep -Fq -- "--plan" <<<"$destroy_help"
grep -Fq -- "--apply" <<<"$destroy_help"

target_help="$($sol target --help=plain)"
for command in show reconcile; do
  grep -Eq "^[[:space:]]+$command[[:space:]]" <<<"$target_help"
done

root_help="$($sol --help=plain)"
if grep -Eq "^[[:space:]]+cloud[[:space:]]" <<<"$root_help"; then
  echo "test_target_command_surface: the removed sol cloud group is still public" >&2
  exit 1
fi

check_removed() {
  local label="$1"
  shift
  set +e
  output="$("$sol" "$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 124 ] || ! grep -Fq "unknown command '" <<<"$output"; then
    echo "test_target_command_surface: the removed '$label' was accepted:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

check_removed "sol cloud" cloud prod/aws/us-east-1
check_removed "sol cloud bootstrap" cloud bootstrap prod/aws/us-east-1 --apply
check_removed "sol cloud plan" cloud plan prod/aws/us-east-1
check_removed "sol cloud apply" cloud apply prod/aws/us-east-1
check_removed "sol cloud destroy" cloud destroy prod/aws/us-east-1 --apply

echo "test_target_command_surface: sol destroy is top-level, sol target owns the ownership audit, and there is no sol cloud group."
