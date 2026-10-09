#!/usr/bin/env bash
set -euo pipefail

sol="$1"
help="$($sol cloud --help=plain)"
for command in destroy reconcile; do
  grep -Eq "^[[:space:]]+$command[[:space:]]" <<<"$help"
done
for command in apply plan bootstrap; do
  if grep -Eq "^[[:space:]]+$command[[:space:]]" <<<"$help"; then
    echo "test_cloud_command_surface: sol cloud $command is still public" >&2
    exit 1
  fi
done

set +e
output="$($sol cloud bootstrap prod/aws/us-east-1 --apply 2>&1)"
status=$?
set -e
if [ "$status" -ne 124 ] || ! grep -Fq "unknown command 'bootstrap'" <<<"$output"; then
  echo "test_cloud_command_surface: the removed bootstrap command was accepted:" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo "test_cloud_command_surface: only destroy/reconcile remain public under sol cloud."
