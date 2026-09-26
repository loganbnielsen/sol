#!/bin/sh
# FEAT-101 / DEC-049: a release build is one built with SOL_RELEASE_VERSION set,
# and only that. The value names the release's bundle directory
# (share/sol/<version>/) and its migration runner, so it must be a plain
# version: reject anything else rather than embed it.
v="${SOL_RELEASE_VERSION:-}"
if [ -z "$v" ]; then
  echo 'let release_version = None'
  exit 0
fi
if ! printf '%s' "$v" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
  echo "SOL_RELEASE_VERSION=$v is not a version (expected e.g. v0.1.0 or 0.1.0-rc.1)" >&2
  exit 1
fi
printf 'let release_version = Some "%s"\n' "$v"
