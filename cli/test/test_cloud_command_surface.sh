#!/usr/bin/env bash
set -euo pipefail

sol="$1"

# cmdliner colors its errors when stderr is a terminal, so pin a dumb terminal: the
# assertions below match the message text, and a colored run would hide it.
export TERM=dumb
export NO_COLOR=1

# The target destroy command is top-level now. It resolves the selected target the same
# way `sol plan` and `sol deploy` do, and keeps the destructive confirmation: `--plan` is
# the default and `--apply` is required to mutate anything.
destroy_help="$($sol destroy --help=plain)"
grep -Eq "^[[:space:]]+sol destroy" <<<"$destroy_help"
grep -Fq -- "--plan" <<<"$destroy_help"
grep -Fq -- "--apply" <<<"$destroy_help"

# `sol cloud` keeps only the non-destructive reconcile.
help="$($sol cloud --help=plain)"
grep -Eq "^[[:space:]]+reconcile[[:space:]]" <<<"$help"
for command in destroy apply plan bootstrap; do
  if grep -Eq "^[[:space:]]+$command[[:space:]]" <<<"$help"; then
    echo "test_cloud_command_surface: sol cloud $command is still public" >&2
    exit 1
  fi
done

check_removed() {
  local subcommand="$1"
  set +e
  output="$($sol cloud "$subcommand" prod/aws/us-east-1 --apply 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 124 ] || ! grep -Fq "unknown command '$subcommand'" <<<"$output"; then
    echo "test_cloud_command_surface: the removed 'sol cloud $subcommand' was accepted:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

check_removed bootstrap
check_removed destroy

echo "test_cloud_command_surface: sol destroy is top-level and only reconcile remains under sol cloud."
