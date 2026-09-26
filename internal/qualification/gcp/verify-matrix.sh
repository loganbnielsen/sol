#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 RESULTS.tsv [MATRIX.tsv]" >&2; exit 2; }
[[ $# -ge 1 && $# -le 2 ]] || usage
results=$1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
matrix=${2:-"$repo_root/internal/qualification/gcp/gcp-production-single-region-v1-matrix.tsv"}
[[ -r "$matrix" ]] || { echo "matrix is not readable: $matrix" >&2; exit 2; }
[[ -r "$results" ]] || { echo "results are not readable: $results" >&2; exit 2; }

awk -F '\t' '
  function fail(message) { print "matrix verification: " message > "/dev/stderr"; failed = 1 }
  FNR == NR {
    if (FNR == 1) {
      if ($0 != "invariant_id\trequired_evidence\tscenario\tpass_condition\tevidence") fail("invalid matrix header")
      next
    }
    if (NF != 5) fail("matrix row " FNR " has " NF " fields; expected 5")
    if ($1 !~ /^INV-[A-Z]+-[0-9]+$/) fail("invalid invariant id at matrix row " FNR ": " $1)
    if ($2 != "MECHANISM" && $2 != "BEHAVIORAL") fail("invalid required evidence for " $1 ": " $2)
    if ($1 in required) fail("duplicate matrix invariant: " $1)
    required[$1] = $2
    count++
    next
  }
  FNR == 1 {
    if ($0 != "invariant_id\tresult\tevidence_class\tevidence_ref\tnote") fail("invalid results header")
    next
  }
  {
    if (NF != 5) fail("results row " FNR " has " NF " fields; expected 5")
    id = $1
    if (!(id in required)) { fail("unknown invariant in results: " id); next }
    if (id in seen) fail("duplicate result: " id)
    seen[id] = 1
    if ($2 != "PASS") fail(id " result is " $2 ", expected PASS")
    if ($3 != required[id]) fail(id " evidence class is " $3 ", expected " required[id])
    if ($4 == "" || $4 == "-") fail(id " has no evidence reference")
  }
  END {
    for (id in required) if (!(id in seen)) fail("missing result: " id)
    if (count == 0) fail("matrix has no invariant rows")
    if (failed) exit 1
  }
' "$matrix" "$results"

bundle_dir=$(cd -- "$(dirname -- "$results")" && pwd)
evidence_failed=0
while IFS=$'\t' read -r invariant_id _ _ evidence_ref _; do
  [[ "$invariant_id" == "invariant_id" ]] && continue
  if [[ "$evidence_ref" == /* || "$evidence_ref" == ".." || "$evidence_ref" == ../* || "$evidence_ref" == */../* ]]; then
    echo "matrix verification: $invariant_id evidence escapes the bundle: $evidence_ref" >&2
    evidence_failed=1
  elif [[ ! -e "$bundle_dir/$evidence_ref" ]]; then
    echo "matrix verification: $invariant_id evidence does not exist in the bundle: $evidence_ref" >&2
    evidence_failed=1
  fi
done <"$results"
[[ $evidence_failed -eq 0 ]] || exit 1
invariant_count=$(($(wc -l <"$matrix") - 1))
echo "GCP qualification matrix PASS ($invariant_count invariants)"
