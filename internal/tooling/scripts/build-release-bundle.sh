#!/usr/bin/env bash
# FEAT-101 / DEC-049: build the Sol release archive.
#
#   sol-<version>/
#     bin/sol                               the release binary (SOL_RELEASE_VERSION=<version>)
#     share/sol/<version>/VERSION           the release this bundle belongs to
#     share/sol/<version>/platform/         every tracked file under platform/
#     share/sol/<version>/migration-runner-image
#                                           the runner published with this release,
#                                           by digest (<image>@sha256:<64 hex>)
#     share/sol/<version>/SUPPORT_REFS      the support-library commits it was built
#                                           against, when given (--support-refs)
#
# The archive's top directory is an installation prefix: put sol-<version>/bin on
# PATH, or copy bin/ and share/ into an existing prefix. The binary finds its
# assets at <its dir>/../share/sol/<version>/ and nowhere else.
#
# Usage:
#   build-release-bundle.sh --version <v> --runner-image <image@sha256:...> --out <dir>
#     [--binary <path>]   use an already-built release binary instead of building one
#     [--support-refs <file>]  record the build's support-package snapshot
#
# Only tracked files are bundled (git ls-files), so local Terraform state,
# .terraform/ directories and other scratch never ship.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
version="" runner="" out="" binary="" support_refs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --runner-image) runner="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --binary) binary="$2"; shift 2 ;;
    --support-refs) support_refs="$2"; shift 2 ;;
    *) echo "build-release-bundle: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$version" ] && [ -n "$runner" ] && [ -n "$out" ] || {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
if ! [[ "$runner" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "build-release-bundle: --runner-image must be a digest reference (<image>@sha256:<64 hex>), got $runner" >&2
  exit 2
fi

if [ -z "$binary" ]; then
  (cd "$root" && SOL_RELEASE_VERSION="$version" dune build cli/bin/main.exe)
  binary="$root/_build/default/cli/bin/main.exe"
fi
reported="$("$binary" --version)"
if [ "$reported" != "$version" ]; then
  echo "build-release-bundle: $binary reports version '$reported', not $version -- build it with SOL_RELEASE_VERSION=$version" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
prefix="$stage/sol-$version"
share="$prefix/share/sol/$version"
mkdir -p "$prefix/bin" "$share"
install -m 0755 "$binary" "$prefix/bin/sol"
printf '%s\n' "$version" >"$share/VERSION"
printf '%s\n' "$runner" >"$share/migration-runner-image"
if [ -n "$support_refs" ]; then cp "$support_refs" "$share/SUPPORT_REFS"; fi
git -C "$root" ls-files -z -- platform | (cd "$root" && xargs -0 cp --parents -t "$share")

mkdir -p "$out"
archive="$out/sol-$version-linux-x86_64.tar.gz"
tar -C "$stage" -czf "$archive" "sol-$version"
echo "$archive"
