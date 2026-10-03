#!/usr/bin/env bash

sol_under_test_die() {
  printf 'sol-under-test: %s\n' "$1" >&2
  exit 2
}

sol_under_test_resolve() {
  local install="${SOL_INSTALL:-}"
  if [ -z "$install" ]; then
    sol_under_test_die "set SOL_INSTALL to the extracted release prefix (the directory holding bin/sol and share/sol/<version>); a live qualification runs the artifact a user installs, never a repository build"
  fi
  [ -d "$install" ] || sol_under_test_die "SOL_INSTALL=$install is not a directory"
  install="$(cd "$install" && pwd)"
  SOL="$install/bin/sol"
  [ -x "$SOL" ] ||
    sol_under_test_die "no executable at $SOL; extract sol-<version>-linux-x86_64.tar.gz and set SOL_INSTALL to its sol-<version> prefix"
  local version
  if ! version="$("$SOL" --version 2>/dev/null)"; then
    sol_under_test_die "$SOL --version failed; the installed release must run on this host"
  fi
  case "$version" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) sol_under_test_die "$SOL reports '$version', which is a development build; a live qualification uses the installed release bundle (DEC-049)" ;;
  esac
  SOL_BUNDLE_VERSION="$version"
  SOL_PLATFORM_ROOT="$install/share/sol/$version/platform"
  [ -f "$SOL_PLATFORM_ROOT/shared/components.json" ] ||
    sol_under_test_die "release $version has no platform bundle at $SOL_PLATFORM_ROOT"
  local runner_file="$install/share/sol/$version/migration-runner-image"
  [ -f "$runner_file" ] ||
    sol_under_test_die "release $version records no migration runner in $runner_file"
  SOL_RUNNER_IMAGE="$(head -n 1 "$runner_file")"
  case "$SOL_RUNNER_IMAGE" in
    *@sha256:*) ;;
    *) sol_under_test_die "release $version names migration runner '$SOL_RUNNER_IMAGE', which is not a digest reference" ;;
  esac
  unset SOL_HOME
}

sol_under_test_record_identity() {
  local dir="$1"
  mkdir -p "$dir"
  {
    printf 'sol_install: %s\n' "$SOL_INSTALL"
    printf 'sol_version: %s\n' "$SOL_BUNDLE_VERSION"
    printf 'migration_runner_image: %s\n' "$SOL_RUNNER_IMAGE"
  } >"$dir/sol-identity.txt"
}
