#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
source "$root/internal/ci/lib/scratch_repo.sh"
scratch_repo_sanitize

unit_test_dirs=(
  framework/ocaml/kafka-eio-service/ framework/ocaml/sol-env/ framework/ocaml/sol-fn/
  framework/ocaml/sol-jobs/ framework/ocaml/sol-obs/ framework/ocaml/sol-outbox/
  framework/ocaml/sol-runtime/ framework/ocaml/sol-svc/ framework/ocaml/sol-worker/
  cli/test/ internal/tooling/style_audit/ internal/tooling/soldev/test/
)

checks=(
  "_build/default/internal/tooling/soldev/bin/main.exe pipeline validate"
  "git diff --name-status -M origin/main...HEAD -- internal/pipeline/tickets | bash internal/ci/check_ticket_transitions.sh"
  "bash internal/ci/check_examples_self_contained.sh"
  "bash internal/ci/check_gcloud_interface.sh"
  "bash internal/ci/check_json_decode_boundary.sh"
  "bash internal/ci/check_library_output.sh"
  "bash internal/ci/check_manifests_are_values.sh"
  "bash internal/ci/check_no_comments.sh"
  "bash internal/ci/check_no_exception_control_flow.sh"
  "bash internal/ci/check_platform_assets_owner.sh"
  "bash internal/ci/check_result_syntax.sh"
  "bash internal/ci/check_single_runner.sh"
  "bash internal/ci/check_support_refs.sh"
  "bash internal/ci/test_authority_check.sh"
  "bash internal/ci/test_classify_changes.sh"
  "bash internal/ci/test_examples_self_contained.sh"
  "bash internal/ci/test_framework_ci_coverage.sh"
  "bash internal/ci/test_hook_install.sh"
  "bash internal/ci/test_scratch_repo.sh"
  "bash internal/ci/test_json_decode_boundary.sh"
  "bash internal/ci/test_library_output.sh"
  "bash internal/ci/test_manifests_are_values.sh"
  "bash internal/ci/test_no_comments.sh"
  "bash internal/ci/test_no_exception_control_flow.sh"
  "bash internal/ci/test_ocamlformat.sh"
  "bash internal/ci/test_pipeline_validate.sh"
  "bash internal/ci/test_platform_assets_owner.sh"
  "bash internal/ci/test_result_syntax.sh"
  "bash internal/ci/test_single_runner.sh"
  "bash internal/ci/test_support_refs.sh"
  "bash internal/ci/test_test_reachability.sh"
  "bash internal/ci/test_ticket_move.sh"
  "bash internal/ci/test_ticket_transitions.sh"
  "bash internal/ci/test_workflow_paths.sh"
  "internal/ci/check_no_account_artifacts.sh"
  "internal/ci/check_ocamlformat.sh --all"
  "internal/ci/check_provider_dispatch.sh ."
  "internal/ci/check_provider_roots.sh ."
  "internal/ci/check_runtime_secret_identity.sh"
  "internal/ci/check_signal_handler_duplication.sh"
  "internal/ci/test_cluster_access_identity.sh"
  "internal/ci/test_destroy_completeness_check.sh"
  "internal/ci/test_gcp_provisioner_role.sh"
  "internal/ci/test_no_account_artifacts.sh"
  "internal/ci/test_provider_dispatch_check.sh"
  "internal/ci/test_provider_roots.sh"
  "internal/ci/test_public_cloud_lifecycle.sh"
  "internal/ci/test_publisher_deployer_boundary.sh"
  "internal/ci/test_qualification_assertions.sh"
  "internal/ci/test_qualification_transport_check.sh"
  "internal/ci/test_readiness_invocations_check.sh"
  "internal/ci/test_scrub_whoami_capture.sh"
  "python3 internal/ci/check_authorization_fence.py ."
  "python3 internal/ci/check_cli_reference.py"
  "python3 internal/ci/check_deploy_identity_iam.py ."
  "python3 internal/ci/check_destroy_completeness.py ."
  "python3 internal/ci/check_framework_ci_coverage.py"
  "python3 internal/ci/check_framework_doc_signatures.py"
  "python3 internal/ci/check_operator_diagnostics.py"
  "python3 internal/ci/check_qualification_transport.py"
  "python3 internal/ci/check_resource_identity.py ."
  "python3 internal/ci/check_test_reachability.py"
  "python3 internal/ci/check_ticket_overwrites.py --base origin/main"
  "python3 internal/ci/check_unconditional_guard_tooling.py ."
  "python3 internal/ci/check_workflow_paths.py"
  "python3 internal/ci/test_cli_reference_check.py"
  "python3 internal/ci/test_authorization_fence_check.py"
  "python3 internal/ci/test_deploy_identity_iam_check.py"
  "python3 internal/ci/test_framework_doc_signatures.py"
  "python3 internal/ci/test_operator_diagnostics_check.py"
  "python3 internal/ci/test_ticket_overwrites.py"
)

if command -v opam >/dev/null; then
  eval "$(opam env 2>/dev/null)"
fi

started=$SECONDS
echo "fast checks: building (the checks read built artifacts)"
if ! build_output="$(dune build 2>&1)"; then
  printf '%s\n' "$build_output"
  echo "fast checks: build failed; no checks run"
  exit 1
fi

echo "fast checks: unit tests (serial: they hold dune's build lock)"
if ! unit_output="$(dune test "${unit_test_dirs[@]}" 2>&1)"; then
  printf '%s\n' "$unit_output"
  echo "fast checks: unit tests failed; no further checks run"
  exit 1
fi

results="$(mktemp -d)"
trap 'rm -rf "$results"' EXIT

run_check() {
  local index=$1
  local check_started=$SECONDS
  bash -o pipefail -c "${checks[$index]}" >"$results/$index.out" 2>&1
  echo "$? $((SECONDS - check_started))" >"$results/$index.status"
}

parallelism="$(nproc 2>/dev/null || echo 4)"
echo "fast checks: running ${#checks[@]} checks, $parallelism at a time"
for index in "${!checks[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$parallelism" ]; do
    wait -n
  done
  run_check "$index" &
done
wait

failed=()
for index in "${!checks[@]}"; do
  read -r code seconds <"$results/$index.status"
  if [ "$code" -eq 0 ]; then
    printf 'PASS %4ss  %s\n' "$seconds" "${checks[$index]}"
  else
    printf 'FAIL %4ss  %s\n' "$seconds" "${checks[$index]}"
    failed+=("$index")
  fi
done

for index in "${failed[@]}"; do
  echo ""
  echo "──── FAIL: ${checks[$index]}"
  cat "$results/$index.out"
done

echo ""
echo "fast checks: ${#failed[@]}/${#checks[@]} failed in $((SECONDS - started))s"
[ "${#failed[@]}" -eq 0 ]
