#!/bin/sh
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
