#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
matrix="$repo_root/docs/qualification/gcp-production-single-region-v1-matrix.tsv"
verifier="$script_dir/verify-matrix.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_results() {
  awk -F '\t' 'BEGIN { OFS="\t"; print "invariant_id", "result", "evidence_class", "evidence_ref", "note" }
    NR > 1 { print $1, "PASS", $2, "evidence/" $1 ".txt", "qualified" }' "$matrix"
}

mkdir -p "$tmp/evidence"
while IFS=$'\t' read -r invariant_id _; do
  [[ "$invariant_id" == "invariant_id" ]] && continue
  : >"$tmp/evidence/$invariant_id.txt"
done <"$matrix"
make_results >"$tmp/pass.tsv"
"$verifier" "$tmp/pass.tsv" "$matrix" >/dev/null

awk -F '\t' 'BEGIN { OFS="\t" } $1 == "INV-AUTH-4" { $2="FAIL" } { print }' "$tmp/pass.tsv" >"$tmp/fail.tsv"
if "$verifier" "$tmp/fail.tsv" "$matrix" >"$tmp/fail.out" 2>&1; then
  echo "expected a failing invariant to fail verification" >&2; exit 1
fi
grep -q 'INV-AUTH-4 result is FAIL' "$tmp/fail.out"

awk -F '\t' '$1 != "INV-DESTROY-4"' "$tmp/pass.tsv" >"$tmp/missing.tsv"
if "$verifier" "$tmp/missing.tsv" "$matrix" >"$tmp/missing.out" 2>&1; then
  echo "expected a missing invariant to fail verification" >&2; exit 1
fi
grep -q 'missing result: INV-DESTROY-4' "$tmp/missing.out"

awk -F '\t' 'BEGIN { OFS="\t" } $1 == "INV-EVID-1" { $3="STATIC" } { print }' "$tmp/pass.tsv" >"$tmp/weak.tsv"
if "$verifier" "$tmp/weak.tsv" "$matrix" >"$tmp/weak.out" 2>&1; then
  echo "expected insufficient evidence to fail verification" >&2; exit 1
fi
grep -q 'INV-EVID-1 evidence class is STATIC, expected MECHANISM' "$tmp/weak.out"

rm "$tmp/evidence/INV-EVID-4.txt"
if "$verifier" "$tmp/pass.tsv" "$matrix" >"$tmp/evidence.out" 2>&1; then
  echo "expected a missing evidence artifact to fail verification" >&2; exit 1
fi
grep -q 'INV-EVID-4 evidence does not exist in the bundle' "$tmp/evidence.out"

echo "verify-matrix tests PASS"
