#!/usr/bin/env bash
set -euo pipefail

# HARDEN-003: assertions must be able to fail. These refuse to pass on a missing
# or empty target, which is the vacuous-assertion failure mode: an assertion that
# greps a path the run never wrote cannot fail, and so looks like coverage.
# shellcheck source=qualification_assertions.sh
. "$(cd "$(dirname "$0")" && pwd)/qualification_assertions.sh"

root="$(git rev-parse --show-toplevel)"
sol="$(realpath "${1:-$root/_build/default/cli/bin/main.exe}")"
tmp="$(mktemp -d)"
# DEC-040: a green exit code must not be able to mean a fixture is corrupt. If a splice
# swallows a heredoc terminator the generated stub runs to end-of-file, and this harness
# still passes -- bash's "delimited by end-of-file" warning is the only sign. Assert the
# invariant directly: every generator heredoc is closed. Checked here rather than trusted to
# memory, and it is the check that would have caught the splice that produced a false green.
heredocs_open=$(grep -cE "^cat >.*<<'EOF'" "$0")
heredocs_close=$(grep -cE '^EOF$' "$0")
if [ "$heredocs_open" != "$heredocs_close" ]; then
  echo "generator heredocs are unbalanced: $heredocs_open opened, $heredocs_close closed" >&2
  echo "a generated file is likely running past its terminator, so a fixture is corrupt" >&2
  exit 1
fi
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work/sol" "$tmp/markers"

# ADR 0003: a postgres resource plus the production profile is what makes
# terraform_vars force the Ready/Production invariant rds_deletion_protection=true.
# Its type is app shape, so sol.yml declares it (DEC-047); a target only sizes it.
cat >"$tmp/work/sol.yml" <<'EOF'
project: lifecycle-test
resources:
  app_db:
    type: postgres
EOF
# FEAT-100: both targets live in sol/environments.yml under the prod environment.
#
# The GCP target carries no `profile` (the production profile asserts the AWS
# substrate, matrix A5) and it states its retention, which DEC-033 requires of a
# target that destroys. `none` is not decoration here: Sol cannot retain anything on
# GCP yet -- Cloud SQL deletes its backups with the instance -- so the default
# `final-snapshot` is refused rather than quietly discarded, and a disposable
# qualification target says out loud that it keeps nothing. It omits app_db, as its
# own target file used to by not declaring one.
cat >"$tmp/work/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      # ADR 0003: a production-profile target makes terraform_vars inject the
      # Ready/Production invariant rds_deletion_protection=true, which is exactly
      # the policy the Destroy policy must override after PrepareDestroy (finding 15).
      profile: production-single-region
      base_domain: example.test
      cluster_name: lifecycle-test
      letsencrypt_email: ops@example.test
      cluster_endpoint_cidr: 203.0.113.0/24
      state_bucket: lifecycle-state
      # REFAC-098: provider-native identity lives in the provider's own block.
      aws:
        state_lock_table: lifecycle-lock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        # HARDEN-002 run 3, finding 11: must reach the provider root's terraform argv
        # so the module creates the deploy EKS access entry (INFRA-025).
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
      resources:
        app_db:
          size: small
    gcp/us-central1:
      base_domain: qual.example.test
      cluster_name: sol-qual
      letsencrypt_email: ops@example.test
      state_bucket: sol-qualification-tfstate
      destroy_retention: none
      gcp:
        project_id: sol-qualification
        provisioner_impersonator: user:qualification-operator@example.test
      resources:
        app_db:
          omit: true
EOF

cat >"$tmp/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'terraform %s\n' "$*" >>"$LIFECYCLE_LOG"
# DEC-050: like the real init, write Terraform's own directory into the working
# directory it was given, so a write into Sol's assets would be observable.
for arg in "$@"; do
  case "$arg" in -chdir=*) tf_chdir="${arg#-chdir=}" ;; esac
done
case " $* " in
  *" init "*) mkdir -p "${tf_chdir:-.}/.terraform" && : >"${tf_chdir:-.}/.terraform/fake-init" ;;
esac
# HARDEN-002 run 4, finding 12: record the kubeconfig env the platform Terraform
# actually receives. The base providers read KUBE_CONFIG_PATH/KUBE_CONFIG_PATHS
# (not KUBECONFIG), so the assertion below fails if that stops being exported.
[ -n "${KUBE_CONFIG_PATH:-}" ] && printf 'env KUBE_CONFIG_PATH=%s\n' "$KUBE_CONFIG_PATH" >>"$LIFECYCLE_LOG"
[ -n "${KUBE_CONFIG_PATHS:-}" ] && printf 'env KUBE_CONFIG_PATHS=%s\n' "$KUBE_CONFIG_PATHS" >>"$LIFECYCLE_LOG"
fail_once() {
  [ "${FAIL_ON:-}" = "$1" ] || return 1
  marker="$FAIL_MARKER_DIR/$1"
  [ ! -e "$marker" ] || return 1
  : >"$marker"
  return 0
}
case "$*" in
  *" init "*|*" init")
    case "$*" in *-backend-config=*) : ;; *) exit 91 ;; esac
    case "$*" in *cloud/aws/platform* | *cloud/gcp/platform*) if fail_once platform-init; then exit 20; fi ;; esac
    ;;
  *" output -json"*)
    if [ "${OUTPUT_ABSENT:-}" = 1 ]; then printf '{}\n'; exit 0; fi
    case " $* " in
      *cloud/gcp/cluster*)
        cat <<'JSON'
{"cluster_name":{"value":"sol-qual"},"project_id":{"value":"sol-qualification"},"region":{"value":"us-central1"},"artifact_registry":{"value":"us-central1-docker.pkg.dev/sol-qualification/sol-qual"},"provisioner_service_account":{"value":"sol-qual-provisioner@sol-qualification.iam.gserviceaccount.com"}}
JSON
        exit 0
        ;;
    esac
    if fail_once outputs; then exit 20; fi
    # HARDEN-002 run 3, finding 10: terraform 1.9.8 OMITS an output whose value
    # is null, so a real default target (durable observability disabled) has no
    # loki_*/thanos_* keys at all. The fixture must match that, or the harness
    # cannot reproduce the live `Can't get member 'value' of non-object type
    # null` crash this scenario exists to guard.
    cat <<'JSON'
{"cluster_name":{"value":"lifecycle-test"},"cluster_access_role_arn":{"value":"arn:aws:iam::111122223333:role/sol-cluster-access"},"cert_manager_irsa_arn":{"value":"arn:aws:iam::111122223333:role/cert-manager"},"grafana_irsa_arn":{"value":null},"managed_resource_dashboards":{"value":{}}}
JSON
    ;;
  *" plan "*)
    if fail_once plan; then exit 20; fi
    case " $* " in
      *" -out="*)
        # HARDEN-004 step 3: a destroy-path apply is planned to a file first, the
        # plan is classified, and the *saved plan* is applied. Record the plan's
        # scope and variables beside the file, so `show -json` and `apply` model
        # the same plan. A stub that re-derived them would not be exercising the
        # property that what was applied is what was asserted.
        plan_file=""
        for arg in "$@"; do
          case "$arg" in
            -out=*) plan_file="${arg#-out=}" ;;
          esac
        done
        [ -n "$plan_file" ] || {
          echo "plan without a -out path" >&2
          exit 92
        }
        # Both of GCP's guards are lifted by one planned transition, and the
        # target's root defaults are protection-on, so a plan in the destroy
        # window that omits either override silently turns protection back on.
        case " $* " in
          *" -target=google_sql_database_instance.postgres "*)
            case " $* " in
              *" -var=sql_deletion_protection=false "*) : ;;
              *) exit 95 ;;
            esac
            case " $* " in
              *" -target=google_container_cluster.main "*) : ;;
              *) exit 96 ;;
            esac
            case " $* " in
              *" -var=gke_deletion_protection=false "*) : ;;
              *) exit 97 ;;
            esac
            ;;
        esac
        : >"$plan_file"
        printf '%s\n' "$*" >"$plan_file.args"
        ;;
    esac
    ;;
  *" show -json"*)
    # A saved-plan read (HARDEN-004 step 3): the last argument is the plan file.
    # The resource changes are what the plan assertion classifies, so the fixture
    # has to carry real addresses and actions.
    case "${!#}" in
      *.tfplan)
        plan_args="$(cat "${!#}.args")"
        changes=""
        add_change() {
          [ -z "$changes" ] || changes="$changes,"
          changes="$changes{\"address\":\"$1\",\"type\":\"$2\",\"mode\":\"managed\",\"change\":{\"actions\":[\"$3\"]}}"
        }
        case " $plan_args " in
          *" -target=aws_db_instance.postgres "*)
            add_change "aws_db_instance.postgres" "aws_db_instance" "update"
            ;;
        esac
        case " $plan_args " in
          *" -target=google_sql_database_instance.postgres "*)
            add_change "google_sql_database_instance.postgres" "google_sql_database_instance" "update"
            ;;
        esac
        case " $plan_args " in
          *" -target=google_container_cluster.main "*)
            add_change "google_container_cluster.main" "google_container_cluster" "update"
            ;;
        esac
        case " $plan_args " in
          *" -var=provisioner_bootstrap_admin=true "*)
            case " $plan_args " in
              *" -target=kubernetes_cluster_role_binding.provisioner_bootstrap_admin "*)
                # FND-0058: the binding is `count = var.provisioner_bootstrap_admin
                # ? 1 : 0`, so the plan address carries an instance key. A fixture
                # written with the bare declaration, as this one was, cannot
                # detect a declaration that the plan can never match -- which is
                # exactly how the GCP authority create was refused while the
                # policy permitted it.
                add_change "kubernetes_cluster_role_binding.provisioner_bootstrap_admin[0]" "kubernetes_cluster_role_binding" "create"
                ;;
              *" -target=module.eks "*)
                add_change "module.eks.aws_eks_access_policy_association.this" "aws_eks_access_policy_association" "create"
                ;;
            esac
            ;;
          *" -var=provisioner_bootstrap_admin=false "*)
            case " $plan_args " in
              *" -target=kubernetes_cluster_role_binding.provisioner_bootstrap_admin "*)
                add_change "kubernetes_cluster_role_binding.provisioner_bootstrap_admin" "kubernetes_cluster_role_binding" "delete"
                ;;
              *" -target=module.eks "*)
                add_change "module.eks.aws_eks_access_policy_association.this" "aws_eks_access_policy_association" "delete"
                ;;
            esac
            ;;
        esac
        # INFRA-074 fixture: the cloud apply's untargeted plan drops a workload's
        # ECR repository (a checkout without that workload's Dockerfile). The apply
        # must refuse it unless --confirm-ecr-removal is given.
        if [ "${ECR_REMOVAL:-}" = 1 ]; then
          case " $plan_args " in
            *" -target="*) : ;;
            *cloud/aws/cluster*)
              add_change 'aws_ecr_repository.services[\"old-svc\"]' "aws_ecr_repository" "delete"
              ;;
          esac
        fi
        # HARDEN-004 step 3 refusal fixture: a reconciliation plan that would
        # reconstruct the missing cluster. The assertion must refuse it and never
        # apply it. Guarded merely by the bootstrap variable so the preparation
        # plans are unaffected and the refusal lands on the reconciliation.
        if [ "${PLAN_CREATES_MISSING_CLUSTER:-}" = 1 ]; then
          case " $plan_args " in
            *" -var=provisioner_bootstrap_admin=true "*)
              add_change "google_container_cluster.main" "google_container_cluster" "create"
              ;;
          esac
        fi
        # FND-0055 / B2: the destroy path also reads the plan for what the
        # configuration *declares*, from `planned_values` -- a different question
        # from the `resource_changes` above, which answer "may this apply run?".
        # The declared set here mirrors the state fixture for each root, so the
        # ordinary scenarios have no divergence; DECLARED_ORPHAN adds one address
        # the state fixture does not represent, which is the shape the
        # verification regressions below are about.
        declared=""
        add_declared() {
          [ -z "$declared" ] || declared="$declared,"
          declared="$declared$1"
        }
        case " $plan_args " in
          *cloud/gcp/cluster*)
            add_declared '{"address":"google_compute_network.main","mode":"managed","type":"google_compute_network","values":{"name":"sol-qual","project":"sol-qualification"}}'
            add_declared '{"address":"google_artifact_registry_repository.images","mode":"managed","type":"google_artifact_registry_repository","values":{"repository_id":"sol-qual","location":"us-central1","project":"sol-qualification"}}'
            add_declared '{"address":"google_compute_global_address.sql_peering","mode":"managed","type":"google_compute_global_address","values":{"name":"sol-qual-sql-peering","project":"sol-qualification"}}'
            add_declared '{"address":"google_sql_database_instance.postgres","mode":"managed","type":"google_sql_database_instance","values":{"name":"sol-qual-postgres","region":"us-central1","project":"sol-qualification"}}'
            add_declared '{"address":"google_container_cluster.main","mode":"managed","type":"google_container_cluster","values":{"name":"sol-qual","location":"us-central1","project":"sol-qualification"}}'
            add_declared '{"address":"google_project_iam_member.provisioner_cluster_access","mode":"managed","type":"google_project_iam_member","values":{"project":"sol-qualification"}}'
            if [ "${DECLARED_ORPHAN:-}" = 1 ]; then
              add_declared '{"address":"google_compute_network.orphan","mode":"managed","type":"google_compute_network","values":{"name":"sol-orphan","project":"sol-qualification"}}'
            fi
            ;;
          *cloud/aws/cluster*)
            add_declared '{"address":"module.eks.aws_eks_cluster.this[0]","mode":"managed","type":"aws_eks_cluster","values":{"name":"lifecycle-test"}}'
            add_declared '{"address":"aws_db_instance.postgres","mode":"managed","type":"aws_db_instance","values":{"identifier":"lifecycle-test-postgres"}}'
            ;;
        esac
        printf '{"resource_changes":[%s],"planned_values":{"root_module":{"resources":[%s]}}}\n' \
          "$changes" "$declared"
        exit 0
        ;;
    esac
    # HARDEN-004 step 2 / FND-0044 point 2: the destroy path decides "the
    # substrate exists" from what Terraform's state represents, not from the
    # install-time outputs. A fixture that means "absent target" must therefore
    # empty the state too -- a target whose outputs are missing while its state
    # still owns resources is the half-built case the OCaml suite pins with fakes,
    # and it must NOT be read as absent.
    if [ "${OUTPUT_ABSENT:-}" = 1 ]; then
      printf '{"values":{"root_module":{"resources":[]}}}\n'
      exit 0
    fi
    case " $* " in
      *cloud/gcp/platform*|*cloud/aws/platform*)
        # INFRA-042: the platform root's state. PARTIAL_INSTALL models Attempt 3 --
        # the two cert-manager ClusterIssuers are in state as `kubernetes_manifest`
        # even though the install never installed the CRDs they need. The cluster
        # stub decides whether that kind is served, which is what the recovery is
        # allowed to act on.
        if [ "${PARTIAL_INSTALL:-}" = 1 ]; then
          if [ "${CRD_SERVED:-}" = 1 ]; then
            kind="ClusterIssuer"
          else
            kind="ClusterIssuer"
          fi
          printf '{"values":{"root_module":{"resources":[{"type":"kubernetes_manifest","address":"module.platform.kubernetes_manifest.letsencrypt_prod","values":{"manifest":{"kind":"%s"}}},{"type":"kubernetes_namespace","address":"module.platform.kubernetes_namespace.cert_manager","values":{"metadata":[{"name":"cert-manager"}]}}]}}}\n' \
            "$kind"
        else
          printf '{"values":{"root_module":{"resources":[]}}}\n'
        fi
        exit 0
        ;;
      *cloud/gcp/cluster*)
        # HARDEN-004 step 5: the fixture carries the identities a real `terraform
        # show -json` carries -- self-link, project, location -- because
        # verification queries the identity captured *here* rather than one
        # reconstructed from the cluster name. Without them the captured-identity
        # lookups are UNKNOWN and the destroy is (correctly) unverifiable, which is
        # not what a real target produces.
        #
        # The ${LIFECYCLE_LOG}.destroyed marker is what the substrate destroy leaves
        # behind: Terraform no longer represents anything in this root. That is the
        # postcondition step 5 reads for itself instead of inferring from destroy's
        # exit status. It is scoped to this run's log so one scenario cannot make the
        # next scenario's *pre*-destroy state read empty.
        if [ -e "${LIFECYCLE_LOG}.destroyed" ] \
          && [ "${STATE_RESIDUE_AFTER_DESTROY:-}" != 1 ]; then
          printf '{"values":{"root_module":{"resources":[]}}}\n'
          exit 0
        fi
        sql_guard=true
        gke_guard=true
        [ -e "${GCP_SQL_PREPARED_FILE:-/nonexistent}" ] && sql_guard=false
        [ -e "${GKE_PREPARED_FILE:-/nonexistent}" ] && gke_guard=false
        # The real `terraform show -json` always carries each resource's real
        # `address`; the guarded resources are found by address, not by type
        # (FND-0048), so the fixture has to model that or it is not modelling
        # Terraform. The names are the ones platform/cloud/gcp/cluster/main.tf declares.
        printf '{"values":{"root_module":{"resources":[
          {"address":"google_compute_network.main","type":"google_compute_network","values":{"self_link":"https://www.googleapis.com/compute/v1/projects/sol-qualification/global/networks/sol-qual","project":"sol-qualification","name":"sol-qual"}},
          {"address":"google_artifact_registry_repository.images","type":"google_artifact_registry_repository","values":{"id":"projects/sol-qualification/locations/us-central1/repositories/sol-qual","project":"sol-qualification","location":"us-central1","name":"sol-qual"}},
          {"address":"google_compute_global_address.sql_peering","type":"google_compute_global_address","values":{"self_link":"https://www.googleapis.com/compute/v1/projects/sol-qualification/global/addresses/sol-qual-sql-peering","project":"sol-qualification","name":"sol-qual-sql-peering"}},
          {"address":"google_sql_database_instance.postgres","type":"google_sql_database_instance","values":{"deletion_protection":%s,"self_link":"https://sqladmin.googleapis.com/sql/v1beta4/projects/sol-qualification/instances/sol-qual-postgres","project":"sol-qualification","region":"us-central1"}},
          {"address":"google_container_cluster.main","type":"google_container_cluster","values":{"deletion_protection":%s,"self_link":"https://container.googleapis.com/v1/projects/sol-qualification/locations/us-central1/clusters/sol-qual","project":"sol-qualification","location":"us-central1"}},
          {"address":"google_project_iam_member.provisioner_cluster_access","type":"google_project_iam_member","values":{"project":"sol-qualification","role":"projects/sol-qualification/roles/solProvisionerClusterAccess"}}
        ]}}}\n' \
          "$sql_guard" "$gke_guard"
        exit 0
        ;;
    esac
    if [ -e "${LIFECYCLE_LOG}.destroyed" ] \
      && [ "${STATE_RESIDUE_AFTER_DESTROY:-}" != 1 ]; then
      # The AWS cloud root, emptied by its own destroy (see the GCP branch above).
      printf '{"values":{"root_module":{"resources":[]}}}\n'
      exit 0
    fi
    # The EKS cluster every non-absent case represents: a real substrate has one, and
    # HARDEN-004 step 5 verifies it by its captured identity, so the fixture carries
    # the `id` and `arn` a real state does.
    eks_resource='{"address":"module.eks.aws_eks_cluster.this[0]","type":"aws_eks_cluster","values":{"id":"lifecycle-test","arn":"arn:aws:eks:us-east-1:111122223333:cluster/lifecycle-test"}}'
    if [ "${RDS_ABSENT:-}" = 1 ]; then
      # The cloud substrate exists (the EKS cluster is represented) but this target
      # never created an RDS instance. Under HARDEN-004 step 2 the substrate's
      # existence is what the state represents, so this must stay distinct from the
      # wholly-absent case (empty state) -- hence a non-RDS resource, not `[]`.
      printf '{"values":{"root_module":{"resources":[%s]}}}\n' "$eks_resource"
    elif [ -e "$RDS_PREPARED_FILE" ]; then
      prepared_value="$(cat "$RDS_PREPARED_FILE")"
      if [ "$prepared_value" = "skip" ]; then
        printf '{"values":{"root_module":{"resources":[%s,{"address":"aws_db_instance.postgres","type":"aws_db_instance","values":{"deletion_protection":false,"skip_final_snapshot":true,"final_snapshot_identifier":null,"identifier":"lifecycle-test-postgres","id":"db-LIFECYCLETEST","arn":"arn:aws:rds:us-east-1:111122223333:db:lifecycle-test-postgres"}}]}}}\n' \
          "$eks_resource"
      else
        # RDS_SNAPSHOT_MISMATCH makes the provider's record disagree with what was
        # prepared, so the production guarantee can be shown to still fail closed.
        printf \
          '{"values":{"root_module":{"resources":[%s,{"address":"aws_db_instance.postgres","type":"aws_db_instance","values":{"deletion_protection":false,"skip_final_snapshot":false,"final_snapshot_identifier":"%s","identifier":"lifecycle-test-postgres","id":"db-LIFECYCLETEST","arn":"arn:aws:rds:us-east-1:111122223333:db:lifecycle-test-postgres"}}]}}}\n' \
          "$eks_resource" "${prepared_value}${RDS_SNAPSHOT_MISMATCH:+-other}"
      fi
    else
      printf \
        '{"values":{"root_module":{"resources":[%s,{"address":"aws_db_instance.postgres","type":"aws_db_instance","values":{"deletion_protection":true,"skip_final_snapshot":false,"final_snapshot_identifier":null,"identifier":"lifecycle-test-postgres","id":"db-LIFECYCLETEST","arn":"arn:aws:rds:us-east-1:111122223333:db:lifecycle-test-postgres"}}]}}}\n' \
        "$eks_resource"
    fi
    ;;
  *" apply "*".tfplan")
    # A saved-plan apply (HARDEN-004 step 3). The plan's scope and variables were
    # recorded beside the plan file; the side effects are the same the direct
    # applies used to have, so the existing assertions still observe them.
    plan_args="$(cat "${!#}.args")"
    # HARDEN-004 step 4 regression: under the refusal fixture the refused plan must
    # never reach an apply. Failing loudly here means "the unsafe apply ran", which
    # the scenario's assertions turn into a failure.
    if [ "${PLAN_CREATES_MISSING_CLUSTER:-}" = 1 ]; then
      case " $plan_args " in
        *" -var=provisioner_bootstrap_admin=true "*) exit 99 ;;
      esac
    fi
    case " $plan_args " in
      *" -target=aws_db_instance.postgres "*)
        if fail_once rds-prepare; then exit 20; fi
        for arg in $plan_args; do
          case "$arg" in
            -var=rds_final_snapshot_identifier=*)
              printf '%s' "${arg#-var=rds_final_snapshot_identifier=}" >"$RDS_PREPARED_FILE"
              ;;
            # A prepare that keeps nothing has no identifier to record, and the
            # setting itself is what the verification has to establish.
            -var=rds_skip_final_snapshot=true)
              printf 'skip' >"$RDS_PREPARED_FILE"
              ;;
          esac
        done
        ;;
    esac
    case " $plan_args " in
      *" -target=google_sql_database_instance.postgres "*)
        if fail_once gcp-prepare; then exit 20; fi
        : >"$GCP_SQL_PREPARED_FILE"
        : >"$GKE_PREPARED_FILE"
        ;;
    esac
    case " $plan_args " in
      *" -var=provisioner_bootstrap_admin=true "*)
        # DEC-040: this variable *is* the bootstrap window, so the stub records it
        # and the kubectl stub answers the de-escalation probes from it --
        # permitted while open, denied once closed.
        printf 'true\n' >"$FAIL_MARKER_DIR/bootstrap-window"
        if fail_once cloud; then exit 20; fi
        ;;
      *" -var=provisioner_bootstrap_admin=false "*)
        printf 'false\n' >"$FAIL_MARKER_DIR/bootstrap-window"
        if fail_once deescalate; then exit 20; fi
        ;;
    esac
    ;;
  *cloud/aws/cluster*" apply "*"-target=aws_db_instance.postgres"*)
    if fail_once rds-prepare; then exit 20; fi
    for arg in "$@"; do
      case "$arg" in
        -var=rds_final_snapshot_identifier=*)
          printf '%s' "${arg#-var=rds_final_snapshot_identifier=}" >"$RDS_PREPARED_FILE"
          ;;
        # A prepare that keeps nothing has no identifier to record, and the setting
        # itself is what the verification has to establish.
        -var=rds_skip_final_snapshot=true)
          printf 'skip' >"$RDS_PREPARED_FILE"
          ;;
      esac
    done
    ;;
  *" state rm "*)
    # INFRA-042's recovery: forgetting a resource Terraform cannot address. Logged
    # so the regression can assert which addresses were forgotten, and that a
    # resource whose kind the cluster serves is never among them.
    printf 'state-rm %s\n' "${!#}" >>"$LIFECYCLE_LOG"
    : >"$STATE_RM_FILE"
    ;;
  *cloud/gcp/platform*" destroy "*|*cloud/aws/platform*" destroy "*)
    # The platform destroy. With PARTIAL_INSTALL it fails exactly as Attempt 3 did,
    # until the missing-CRD resources have been forgotten -- and then it succeeds,
    # which is the behaviour the regression has to demonstrate rather than assume.
    if [ "${PARTIAL_INSTALL:-}" = 1 ] && [ ! -e "${STATE_RM_FILE:-/nonexistent}" ]; then
      printf 'Error: API did not recognize GroupVersionKind from manifest (CRD may not be installed)\n' >&2
      exit 1
    fi
    ;;
  *cloud/gcp/cluster*" destroy "*|*cloud/aws/cluster*" destroy "*)
    # HARDEN-004 step 5: the substrate destroy empties this root's state. That is
    # what step 5 reads as its independent postcondition -- rather than trusting
    # this command's exit status -- so the fixture has to model the consequence.
    # STATE_RESIDUE_AFTER_DESTROY models a destroy that left something represented,
    # so the residue path is exercised rather than asserted.
    [ "${STATE_RESIDUE_AFTER_DESTROY:-}" = 1 ] || : >"${LIFECYCLE_LOG}.destroyed"
    ;;
  *cloud/gcp/cluster*" apply "*"-target=google_sql_database_instance.postgres"*)
    if fail_once gcp-prepare; then exit 20; fi
    # Both of GCP's guards are lifted by one applied transition, and the target's
    # root defaults are protection-on, so an apply in the destroy window that omits
    # either override silently turns protection back on.
    case " $* " in
      *" -var=sql_deletion_protection=false "*) : ;;
      *) exit 95 ;;
    esac
    case " $* " in
      *" -target=google_container_cluster.main "*) : ;;
      *) exit 96 ;;
    esac
    case " $* " in
      *" -var=gke_deletion_protection=false "*) : ;;
      *) exit 97 ;;
    esac
    : >"$GCP_SQL_PREPARED_FILE"
    : >"$GKE_PREPARED_FILE"
    ;;
  *cloud/aws/cluster*" apply "*"provisioner_bootstrap_admin=true"*)
    # DEC-040: this variable *is* the bootstrap window, so the stub records it and the
    # kubectl stub answers the de-escalation probes from it -- permitted while open,
    # denied once closed. That makes the offline harness exercise the transition the
    # verification requires rather than asserting a lifecycle it would refuse.
    printf 'true\n' >"$FAIL_MARKER_DIR/bootstrap-window"
    if fail_once cloud; then exit 20; fi
    ;;
  *cloud/aws/cluster*" apply "*"provisioner_bootstrap_admin=false"*)
    printf 'false\n' >"$FAIL_MARKER_DIR/bootstrap-window"
    if fail_once deescalate; then exit 20; fi
    ;;
  *cloud/aws/platform*" apply "*"-target="*|*cloud/gcp/platform*" apply "*"-target="*)
    if fail_once prerequisites; then exit 20; fi
    # FRESH_TARGET modelling: this apply is what installs cert-manager, and so
    # what brings the CRDs the pre-install freshness probe looks for into
    # existence.
    [ -n "${PLATFORM_INSTALLED_FILE:-}" ] && : >"$PLATFORM_INSTALLED_FILE"
    ;;
  *cloud/aws/platform*" apply "*|*cloud/gcp/platform*" apply "*)
    if fail_once platform; then exit 20; fi
    ;;
esac
EOF

cat >"$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'aws %s\n' "$*" >>"$LIFECYCLE_LOG"
  # INFRA-039: Sol resolves credentials per mutating stage through the CLI, so
  # the fake has to answer that (and the identity query) like a working session.
  case "$1 $2" in
    "configure export-credentials")
      if [ "${FAIL_CREDENTIALS:-}" = 1 ]; then
        printf 'Error: could not resolve credentials, session has expired\n' >&2
        exit 254
      fi
      printf 'export AWS_ACCESS_KEY_ID=AKIAHARNESS\n'
      printf 'export AWS_SECRET_ACCESS_KEY=harness-secret\n'
      printf 'export AWS_SESSION_TOKEN=harness-token\n'
      exit 0
      ;;
    "sts get-caller-identity")
      printf 'arn:aws:iam::111122223333:role/harness-qualification\n'
      exit 0
      ;;
  esac
# Destroy-path verification wants the opposite of apply's: every resource
# reports absent. Apply and destroy never run in the same process, so one
# env toggle (set only around destroy invocations below) is enough to flip
# the whole mock rather than keying every case on both directions.
if [ "${DESTROYING:-}" = 1 ]; then
  # HARDEN-004 step 5: the captured-identity lookups are what the destroy now
  # verifies with, and each of the three answers has to be reachable from here --
  # an explicit not-found (the ordinary case), a returned resource (a residue that
  # must fail), and an error that says nothing about the resource (UNKNOWN, which
  # must fail rather than pass).
  case "$1 $2" in
    "eks describe-cluster"|"eks describe-addon"|"rds describe-db-instances")
      if [ "${AWS_VERIFY_UNKNOWN:-}" = 1 ]; then
        echo "An error occurred (Throttling) when calling the operation" >&2
        exit 254
      fi
      if [ "${DESTROYED_RESOURCE_PRESENT:-}" = 1 ]; then
        printf '{"resource":"still here"}\n'
        exit 0
      fi
      case "$1 $2" in
        "rds describe-db-instances")
          echo "An error occurred (DBInstanceNotFound) when calling the operation" >&2
          ;;
        *)
          echo "An error occurred (ResourceNotFoundException) when calling the operation" >&2
          ;;
      esac
      exit 254
      ;;
    "rds describe-db-snapshots")
      # Retention, observed. The final-snapshot query names the identifier the
      # preparation established; the retain-nothing query names the captured
      # instance. RDS_SNAPSHOT_MISSING / RDS_SNAPSHOT_PENDING model the two ways a
      # promised snapshot is not established, and RDS_SNAPSHOT_RESIDUE models a
      # snapshot a retain-nothing destroy should not have left.
      snapshot_id=""
      want_id=0
      for arg in "$@"; do
        if [ "$want_id" = 1 ]; then snapshot_id="$arg"; want_id=0; continue; fi
        [ "$arg" = "--db-snapshot-identifier" ] && want_id=1
      done
      if [ -n "$snapshot_id" ]; then
        if [ "${RDS_SNAPSHOT_MISSING:-}" = 1 ]; then
          echo "An error occurred (DBSnapshotNotFound) when calling the DescribeDBSnapshots operation" >&2
          exit 254
        fi
        status=available
        [ "${RDS_SNAPSHOT_PENDING:-}" = 1 ] && status=creating
        # The first read says `creating`, the second says `available`: a final
        # snapshot is created asynchronously, so the observation has to ride that
        # out rather than abandon the guarantee on the first look.
        if [ "${RDS_SNAPSHOT_CREATING_ONCE:-}" = 1 ] \
          && [ ! -e "$FAIL_MARKER_DIR/snapshot-creating" ]; then
          : >"$FAIL_MARKER_DIR/snapshot-creating"
          status=creating
        fi
        printf '{"DBSnapshots":[{"DBSnapshotIdentifier":"%s","SnapshotType":"manual","Status":"%s"}]}\n' \
          "$snapshot_id" "$status"
        exit 0
      fi
      if [ "${RDS_SNAPSHOT_RESIDUE:-}" = 1 ]; then
        printf '{"DBSnapshots":[{"DBSnapshotIdentifier":"leaked-manual","SnapshotType":"manual","Status":"available"}]}\n'
      else
        printf '{"DBSnapshots":[]}\n'
      fi
      exit 0
      ;;
    "ecr describe-repositories") printf '\n'; exit 0 ;;
    "resourcegroupstaggingapi get-resources") printf '\n'; exit 0 ;;
    "ec2 describe-addresses")
      [ "${AWS_RESIDUAL_KIND:-}" = eip ] && printf 'eipalloc-residual\n' || printf '\n'
      exit 0
      ;;
    "ec2 describe-nat-gateways")
      [ "${AWS_RESIDUAL_KIND:-}" = nat ] && printf 'nat-residual\n' || printf '\n'
      exit 0
      ;;
    "ec2 describe-volumes")
      [ "${AWS_RESIDUAL_KIND:-}" = ebs ] && printf 'vol-residual\n' || printf '\n'
      exit 0
      ;;
    # Anything else (notably "eks update-kubeconfig", still needed to build
    # the platform-phase ephemeral kubeconfig during teardown) falls through
    # to the ordinary logic below.
  esac
fi
if [ "$1 $2" = "eks describe-cluster" ] || [ "$1 $2" = "eks describe-addon" ]; then
  if [ "${FAIL_ON:-}" = cloud-verify ] && [ ! -e "$FAIL_MARKER_DIR/cloud-verify" ]; then
    : >"$FAIL_MARKER_DIR/cloud-verify"; exit 20
  fi
  printf 'ACTIVE\n'; exit 0
fi
case " $* " in
  *" sts assume-role "*)
    # DEC-040: the identity check behind a cluster refusal. It must come before the eks-only
    # guard below, or it never matches and the discriminator scenario passes vacuously.
    if [ "${STS_ASSUME_FAIL:-}" = 1 ]; then
      printf 'An error occurred (AccessDenied) when calling the AssumeRole operation\n' >&2
      exit 255
    fi
    printf '{"Credentials":{"AccessKeyId":"ASIAEXAMPLE"}}\n'
    exit 0
    ;;
esac
[ "$1 $2" = "eks update-kubeconfig" ] || exit 90
case " $* " in
  *" --role-arn arn:aws:iam::111122223333:role/sol-cluster-access "*)
    printf 'sol-cluster-access\n' >"$FAIL_MARKER_DIR/kubeconfig-role"
    ;;
  *" --role-arn arn:aws:iam::111122223333:role/sol-provisioner "*)
    printf 'sol-provisioner\n' >"$FAIL_MARKER_DIR/kubeconfig-role"
    ;;
  *) exit 91 ;;
esac
while [ "$#" -gt 0 ]; do
  if [ "$1" = --kubeconfig ]; then shift; path="$1"; break; fi
  shift
done
[ -n "${path:-}" ] && [ "$KUBECONFIG" = "$path" ] || exit 92
printf '%s\n' "$path" >>"$KUBECONFIG_LOG"
# DEC-040: the access failure is injected in one of two modes, because the two now have
# different expected outcomes. `once` (default) is the transient case a bounded retry must
# ride through; `always` is the persistent case, where the gate must fail after its window
# with the message that the gate did not run.
if [ "${FAIL_ON:-}" = access ] && { [ "${ACCESS_FAIL:-once}" = always ] || [ ! -e "$FAIL_MARKER_DIR/access" ]; }; then
  : >"$FAIL_MARKER_DIR/access"; exit 20
fi
: >"$path"
EOF

# The GCP mechanisms Sol drives: the credential check, cluster credentials, the two
# readiness facts, and absence. One mock flipped by DESTROYING, like the AWS one,
# rather than every case carrying both directions.
cat >"$tmp/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'gcloud %s\n' "$*" >>"$LIFECYCLE_LOG"
# The credential check addresses no project (it is about the caller, not the
# target), so the project guard is applied to the calls that do name one.
case "$1 $2" in
  "auth application-default") : ;;
  *)
    case " $* " in
      *" --project sol-qualification "*|*" --project=sol-qualification "*) : ;;
      *) exit 91 ;;
    esac
    ;;
esac
case "$1 $2" in
  "auth application-default")
    if [ "${FAIL_CREDENTIALS:-}" = 1 ]; then
      printf 'ERROR: (gcloud.auth.application-default.print-access-token) There was a problem refreshing your current auth tokens\n' >&2
      exit 254
    fi
    printf 'ya29.harness-token\n'
    exit 0
    ;;
  "container clusters")
    case " $* " in
      *" get-credentials "*)
        # The stub models the interface gcloud actually has (Attempt 2):
        # `get-credentials` writes to the kubeconfig named by $KUBECONFIG and has no
        # --kubeconfig flag. It accepted one before because it was written from Sol's
        # implementation rather than from the CLI -- which is how a stub silently
        # ratifies the assumption it was built on. The flag's absence is asserted
        # here too, so reintroducing it fails offline as well as in the interface
        # check.
        case " $* " in
          *" --kubeconfig "*) exit 93 ;;
        esac
        path="${KUBECONFIG:-}"
        [ -n "$path" ] || exit 92
        printf '%s\n' "$path" >>"$KUBECONFIG_LOG"
        if [ "${FAIL_ON:-}" = access ] && [ ! -e "$FAIL_MARKER_DIR/access" ]; then
          : >"$FAIL_MARKER_DIR/access"; exit 20
        fi
        : >"$path"
        exit 0
        ;;
      *" describe "*)
        if [ "${DESTROYING:-}" = 1 ]; then
          # The real wording (Attempt 4, reproduced live):
          #   ResponseError: code=404, message=Not found: projects/.../clusters/sol-qual
          # The stub previously answered NOT_FOUND/"was not found", which the
          # verification recognised -- so the harness agreed with the implementation
          # and the live run disagreed with both. A stub must answer like the tool.
          echo "ERROR: (gcloud.container.clusters.describe) ResponseError: code=404, message=Not found: projects/sol-qualification/locations/us-central1/clusters/sol-qual." >&2
          exit 1
        fi
        printf 'RUNNING\n'; exit 0
        ;;
    esac
    ;;
  "sql instances")
    if [ "${DESTROYING:-}" = 1 ]; then
      # The real wording (Attempt 4): `HTTPError 404: The Cloud SQL instance does not exist`.
      echo "ERROR: (gcloud.sql.instances.describe) HTTPError 404: The Cloud SQL instance does not exist." >&2
      exit 1
    fi
    printf 'RUNNABLE\n'; exit 0
    ;;
  "services vpc-peerings")
    if [ "${DESTROYING:-}" = 1 ]; then
      echo "ERROR: (gcloud.services.vpc-peerings.list) NOT_FOUND: The network was not found" >&2
      exit 1
    fi
    printf 'servicenetworking-googleapis-com\n'
    exit 0
    ;;
  "compute networks")
    case " $* " in
      *" describe sol-orphan "*)
        # FND-0055 / B2: the declared/state-absent resource the divergence
        # regressions declare. Its three provider answers have to be reachable
        # from here, because the whole point is which of them the verification
        # is allowed to turn into "absent".
        if [ "${DECLARED_ORPHAN_PRESENT:-}" = 1 ]; then
          printf 'name: sol-orphan\nselfLink: https://www.googleapis.com/compute/v1/projects/sol-qualification/global/networks/sol-orphan\n'
          exit 0
        fi
        if [ "${DECLARED_ORPHAN_UNKNOWN:-}" = 1 ]; then
          echo "ERROR: (gcloud.compute.networks.describe) Throttling: rate exceeded" >&2
          exit 1
        fi
        echo "ERROR: (gcloud.compute.networks.describe) Could not fetch resource: - The resource 'projects/sol-qualification/global/networks/sol-orphan' was not found" >&2
        exit 1
        ;;
    esac
    if [ "${DESTROYING:-}" = 1 ]; then
      # HARDEN-004 step 5: the real wording names the resource's own path, and the
      # verification checks that subject against the project the identity was
      # captured in. A stub that answers without one would leave that check
      # untested -- and the check is the difference between "this object is gone"
      # and "that project is not visible to you", both of which gcloud answers 404.
      echo "ERROR: (gcloud.compute.networks.describe) Could not fetch resource: - The resource 'projects/sol-qualification/global/networks/sol-qual' was not found" >&2
      exit 1
    fi
    exit 0
    ;;
  "artifacts repositories"|"compute addresses")
    if [ "${DESTROYING:-}" = 1 ]; then
      echo "ERROR: (gcloud.$1.$2.describe) NOT_FOUND: Resource was not found" >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 90
EOF

# DEC-040: check the generated stubs parse before anything runs. A syntax error in a stub
# surfaces as a plausible-looking product failure -- an "eks update-kubeconfig failed" message
# that took several rounds to trace back to the stub itself. Cheap assertion, loud failure, so
# this harness cannot fail for a reason that looks like a bug in sol.
for generated in "$tmp/bin/aws" "$tmp/bin/terraform" "$tmp/bin/kubectl" "$tmp/bin/gcloud"; do
  [ -e "$generated" ] || continue
  if ! bash -n "$generated" 2>/dev/null; then
    echo "the generated $(basename "$generated") stub is not valid shell:" >&2
    bash -n "$generated" 2>&1 | head -3 >&2
    exit 1
  fi
done

# The platform stage's host prerequisite (Attempt 3): the kubeconfig gcloud writes
# names this as its exec credential plugin, so every Kubernetes call needs it on
# PATH. Failing without it is free; failing inside the platform apply is not.
cat >"$tmp/bin/gke-gcloud-auth-plugin" <<'EOF'
#!/usr/bin/env bash
# NO_AUTH_PLUGIN models a host without the plugin, which is how Attempt 3 failed:
# after a billable apply, inside the platform stage.
if [ "${NO_AUTH_PLUGIN:-}" = 1 ]; then exit 1; fi
printf 'Kubernetes v0.1.0-harness\n'
exit 0
EOF

cat >"$tmp/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'kubectl %s\n' "$*" >>"$LIFECYCLE_LOG"
# INFRA-042: the cluster's own discovery. The recovery may only forget a resource
# whose kind is *not* here, so the stub has to be able to say both things --
# CRD_SERVED=1 models a cluster where the CRD is present (and the destroy must then
# fail closed rather than forget anything).
# DEC-040: answer the *de-escalation probes* on the same terms the real cluster does.
# Scoped deliberately to the bootstrap-only capability set: Sol also checks that the
# platform provisioner's own RBAC survives the bootstrap removal, and that check asks
# different questions as a different (legitimate) principal. Answering for it here would
# replace the thing being tested with the test.
case " $* " in
  *" auth whoami "*)
    # Whichever role the ephemeral kubeconfig was built for, so a caller inspecting the
    # principal sees the truth.
    # The EKS shape, not a convenience one: a SelfSubjectReview whose identity lives in
    # status.userInfo.extra, where every value is an array of strings -- arn is the STS
    # assumed-role ARN with a session name, canonicalArn is the stable role ARN. Emitting
    # anything simpler here would let the harness pass against a shape no real cluster
    # produces, which is the failure this emulation exists to prevent.
    case "$(cat "$FAIL_MARKER_DIR/kubeconfig-role" 2>/dev/null || true)" in
      sol-provisioner)
        # DEC-040: the first answer is a 401, as a freshly created EKS cluster gives
        # while access-entry or aws-auth propagation catches up for the *correct*
        # principal. The gate must retry that, not read it as a wrong identity.
        # A refusal of the identity call itself, which is the shape an upstream-broken
        # credential takes: the token generates, and the cluster rejects it. Only once the
        # bootstrap window is closed, because that is when the removal has taken effect and
        # the question the discriminator answers arises -- before that the gate would stop
        # the run first, which is correct but not what this scenario is testing.
        if [ "${WHOAMI_REFUSE:-}" = 1 ] &&
          [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null || true)" = "false" ]; then
          printf 'error: You must be logged in to the server (Unauthorized)\n' >&2
          exit 1
        fi
        if [ ! -e "${LIFECYCLE_LOG}.whoami-401-seen" ]; then
          : >"${LIFECYCLE_LOG}.whoami-401-seen"
          printf 'error: You must be logged in to the server (Unauthorized)\n' >&2
          exit 1
        fi
        printf '{"apiVersion":"authentication.k8s.io/v1","kind":"SelfSubjectReview","metadata":{"creationTimestamp":null},"status":{"userInfo":{"username":"arn:aws:sts::111122223333:assumed-role/sol-provisioner/EKSGetTokenAuth","uid":"aws-iam-authenticator:111122223333:AROA","groups":["system:authenticated","sol:platform-provisioners"],"extra":{"arn":["arn:aws:sts::111122223333:assumed-role/sol-provisioner/EKSGetTokenAuth"],"canonicalArn":["arn:aws:iam::111122223333:role/sol-provisioner"],"sessionName":["EKSGetTokenAuth"]}}}}\n'
        ;;
      sol-cluster-access)
        printf '{"apiVersion":"authentication.k8s.io/v1","kind":"SelfSubjectReview","status":{"userInfo":{"username":"arn:aws:sts::111122223333:assumed-role/sol-cluster-access/EKSGetTokenAuth","extra":{"arn":["arn:aws:sts::111122223333:assumed-role/sol-cluster-access/EKSGetTokenAuth"],"canonicalArn":["arn:aws:iam::111122223333:role/sol-cluster-access"]}}}}\n'
        ;;
      *) printf '{"status":{"userInfo":{}}}\n' ;;
    esac
    exit 0
    ;;
  *" auth can-i "*" clusterroles "*|*" auth can-i "*" clusterrolebindings "*)
    # The probe must interrogate *the principal whose elevation is being removed*.
    # Answering for another principal would let a wrong-principal check look like
    # evidence, so this refuses -- the harness asserts the principal requirement rather
    # than merely supplying answers to it.
    if [ "$(cat "$FAIL_MARKER_DIR/kubeconfig-role" 2>/dev/null || true)" != "sol-provisioner" ]; then
      printf 'error: the authorizer was asked about the wrong principal\n' >&2
      exit 90
    fi
    # DEC-040 / FND-0021: a non-authorization failure. Real kubectl exits non-zero here
    # with no `yes`/`no` on stdout, and Sol must read that as indeterminate -- not as a
    # denial. Only after the window closes, so the positive control still observes the
    # capability permitted first. CAN_I_FAIL=1 models it.
    if [ "${CAN_I_FAIL:-}" = 1 ] &&
      [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null || true)" = "false" ]; then
      printf 'error: unable to connect to the server: dial tcp: i/o timeout\n' >&2
      exit 1
    fi
    # INFRA-061 control strictness: one capability comes back indeterminate while the
    # others are permitted, in the window. A control that accepts "any capability
    # permitted" would proceed and only discover the indeterminate at de-escalation,
    # after the platform install; the control must fail early instead.
    if [ "${CAN_I_INDETERMINATE_WHEN_OPEN:-}" = 1 ] &&
      [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null || true)" = "true" ]; then
      case " $* " in
        *" auth can-i create clusterroles "*)
          printf 'maybe\n'
          exit 0
          ;;
      esac
    fi
    # Real kubectl prints the answer on stdout and exits 0/1, and a denial carries a
    # reason after the token (`no - ...`) on the versions that do. The classifier reads
    # the first token, so the stub emits the real shape: matching the whole line would
    # otherwise read every genuine denial as indeterminate.
    if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null || true)" = "true" ]; then
      printf 'yes\n'
      exit 0
    fi
    printf 'no - no RBAC policy matched\n'
    exit 1
    ;;
esac
case " $* " in
  *" api-resources "*)
    printf 'NAME        SHORTNAMES   APIVERSION   NAMESPACED   KIND\n'
    printf 'namespaces  ns           v1           false        Namespace\n'
    printf 'clusterroles             rbac.authorization.k8s.io/v1  false  ClusterRole\n'
    if [ "${CRD_SERVED:-}" = 1 ]; then
      printf 'clusterissuers           cert-manager.io/v1  false  ClusterIssuer\n'
    fi
    exit 0
    ;;
esac

#!/usr/bin/env bash
set -eu
printf 'kubectl %s\n' "$*" >>"$LIFECYCLE_LOG"
[ "$KUBECONFIG" != /ambient/forbidden ] || exit 93
# Destroy verifies platform absence by checking every platform namespace is
# gone; apply never checks this, so DESTROYING is an unambiguous toggle here.
if [ "${DESTROYING:-}" = 1 ]; then
  case "$*" in "get namespace "*) exit 1 ;; esac
fi
# Plan-only fault knobs: an intermediate target whose provisioner RBAC is not
# yet established, one whose cert-manager CRDs are not yet Established, and one
# where the provisioner cannot authenticate to the cluster at all.
if [ "${AUTH_ABSENT:-}" = 1 ]; then
  case "$*" in "auth can-i "*) exit 94 ;; esac
fi
if [ "${RBAC_ABSENT:-}" = 1 ]; then
  case "$*" in
    # Authentication succeeds (empty rule set); only the RBAC checks are denied.
    "auth can-i --list") : ;;
    "auth can-i "*) exit 1 ;;
  esac
fi
if [ "${CRDS_ABSENT:-}" = 1 ]; then
  case "$*" in *"--for=condition=Established"*) exit 1 ;; esac
fi
# FRESH_TARGET models a target that has not been installed yet: the cert-manager
# CRDs do not exist until this run's own prerequisites apply creates them, which
# is what makes the run enter PlatformInstalling rather than PlatformUpdating.
# Gated on the toggle so every other scenario keeps its original cluster.
if [ "${FRESH_TARGET:-}" = 1 ] && [ ! -e "${PLATFORM_INSTALLED_FILE:-/nonexistent}" ]; then
  case "$*" in *"--for=condition=Established"*) exit 1 ;; esac
fi
if [ "${FAIL_ON:-}" = crds ] && [ ! -e "$FAIL_MARKER_DIR/crds" ] &&
   case "$*" in *"--timeout=180s"*) true;; *) false;; esac; then
  : >"$FAIL_MARKER_DIR/crds"; exit 20
fi
if [ "${FAIL_ON:-}" = rbac ] && [ ! -e "$FAIL_MARKER_DIR/rbac" ] &&
   case "$*" in "auth can-i create namespaces") true;; *) false;; esac; then
  : >"$FAIL_MARKER_DIR/rbac"; exit 20
fi
# INFRA-034: readiness is a converging condition, so a single failed sample is
# now waited out rather than fatal. This models the other half of that behaviour:
# a platform that NEVER converges, which must still fail the install (and must
# fail within the bounded deadline rather than waiting forever).
if [ "${FAIL_READINESS_ALWAYS:-}" = 1 ] &&
   case "$*" in *"csidriver/ebs.csi.aws.com"*) true;; *) false;; esac; then
  exit 20
fi
case "$*" in
  "auth can-i "*" -n default") exit 1 ;;
  "auth can-i bind "*|"auth can-i escalate "*) exit 1 ;;
  "get storageclass -o jsonpath="*)
    # The one readiness answer that is the cloud provider's rather than Sol's.
    # STORAGE_CLASS_WRONG models a cluster whose sole default class is backed by
    # the wrong block-storage driver, which must fail the install closed.
    if [ "${STORAGE_CLASS_WRONG:-}" = 1 ]; then
      printf 'gp3|pd.csi.storage.gke.io|true '
    else
      printf 'gp3|ebs.csi.aws.com|true '
    fi
    ;;
  *"service/ingress-nginx-controller"*) printf 'lb.example.test' ;;
  # INFRA-035/036: convergence is read from status, so this fake has to produce
  # the values the readiness predicates parse (`rollout status` has no [--all],
  # which is why the checks no longer use it). A query the fake does not answer
  # returns empty output and the check fails closed, which is the point.
  *"get daemonset -n monitoring -o jsonpath="*) printf '4/4 4/4 ' ;;
  *"get statefulset -n monitoring -o jsonpath="*) printf '1/1 1/1 1/1 ' ;;
  *"get statefulset -n redpanda -o jsonpath="*) printf '3/3 ' ;;
  *"get pvc -n monitoring -o jsonpath="*) printf 'Bound Bound ' ;;
  *"get pvc -n redpanda -o jsonpath="*) printf 'Bound Bound ' ;;
  *"get nodes -o jsonpath="*) printf 'True True True True ' ;;
esac
if [ "${FAIL_ON:-}" = readiness ] && [ ! -e "$FAIL_MARKER_DIR/readiness" ] &&
   case "$*" in *"csidriver/ebs.csi.aws.com"*) true;; *) false;; esac; then
  : >"$FAIL_MARKER_DIR/readiness"; exit 20
fi
EOF
chmod +x "$tmp/bin/terraform" "$tmp/bin/aws" "$tmp/bin/kubectl" "$tmp/bin/gcloud" \
  "$tmp/bin/gke-gcloud-auth-plugin"

export PATH="$tmp/bin:$PATH"
export SOL_HOME="$root"
# INFRA-075: Sol's run logs and state live under $XDG_DATA_HOME/sol (else ~/.local/share/sol),
# not under SOL_HOME. Without this, every scenario below wrote a run into the operator's real
# Sol home, and the shared keep-20 pruning deleted real qualification evidence to make room.
export XDG_DATA_HOME="$tmp/xdg-data"
export TF_VAR_db_password=offline-only
export KUBECONFIG=/ambient/forbidden
export FAIL_MARKER_DIR="$tmp/markers"
# DEC-040: exercise the gate's retry without sleeping through it.
export SOL_WHOAMI_RETRY_INTERVAL_S=0
export KUBECONFIG_LOG="$tmp/kubeconfigs"
export RDS_PREPARED_FILE="$tmp/markers/rds-prepared"
export STATE_RM_FILE="$tmp/markers/state-rm"
export GCP_SQL_PREPARED_FILE="$tmp/markers/gcp-sql-prepared"
export GKE_PREPARED_FILE="$tmp/markers/gke-prepared"
export PLATFORM_INSTALLED_FILE="$tmp/markers/platform-installed"

run_apply() {
  (cd "$tmp/work" && LIFECYCLE_LOG="$1" "$sol" cloud apply prod/aws/us-east-1) >"$1.out" 2>&1
}

run_destroy() {
  (cd "$tmp/work" && DESTROYING=1 LIFECYCLE_LOG="$1" "$sol" cloud destroy prod/aws/us-east-1 --apply) \
    >"$1.out" 2>&1
}

# INFRA-034: `readiness` is deliberately NOT in this list. It is a converging
# condition, not a step that either passes or fails, so a single unmet sample must
# be waited out rather than failing the install. The two scenarios below assert
# both ends of that: a transient unmet sample is survived, and a platform that
# never converges still fails.
for phase in cloud outputs cloud-verify access platform-init prerequisites crds deescalate rbac platform; do
  rm -f "$tmp/markers/$phase"
  # INFRA-061 A: clear the window marker so the assertion below cannot pass vacuously on a
  # value left behind by an earlier run.
  if [ "$phase" = access ]; then rm -f "$FAIL_MARKER_DIR/bootstrap-window"; fi
  log="$tmp/$phase.log"
  # The access phase is persistent here: an injected access failure that never clears must
  # still be fatal, or the retry would quietly turn a hard failure into a pass.
  if (export FAIL_ON="$phase"; export ACCESS_FAIL=always; run_apply "$log"); then
    echo "cloud apply unexpectedly survived injected $phase failure" >&2
    exit 1
  fi
  # FND-0010: cert-manager's readiness gate is a gate, not a warning. `prerequisites` is
  # the targeted platform apply that installs cert-manager (and whose own post-install
  # readiness check must pass); `crds` is the wait for cert-manager's API surface to be
  # Established. If either fails, nothing after cert-manager can work -- the webhook's CA
  # bundle is what every certificate-bearing component depends on -- so the install must
  # stop. A regression that demoted that failure to a warning would show up here as an
  # untargeted platform apply in the argv log.
  if [ "$phase" = prerequisites ] || [ "$phase" = crds ]; then
    if grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* apply ' | grep -v -- '-target=' >/dev/null; then
      echo "FND-0010: a failed cert-manager gate ($phase) still ran the full platform apply:" >&2
      cat "$log.out" >&2
      exit 1
    fi
  fi
  assert_contains "the apply reported its credential principal" "$log.out" \
  "credentials: arn:aws:iam::111122223333:role/harness-qualification" || {
  echo "INFRA-039: the apply did not report the principal its credentials belong to" >&2
  exit 1
}
# INFRA-061 A: the whoami gate runs *after* the bootstrap window is open, so a gate
# failure must remove that access before the run stops. Assert both that the removal apply
# ran and that the emulated window reads closed -- otherwise the run exits with
# provisioner_bootstrap_admin=true still applied on a cluster it just decided it cannot
# verify, which is the wrong end state for a least-privilege change.
if [ "$phase" = access ]; then
  if ! grep -qF 'provisioner_bootstrap_admin=false' "$log"; then
    echo "INFRA-061 A: a failed whoami gate never removed the bootstrap access:" >&2
    cat "$log.out" >&2
    exit 1
  fi
  if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null || true)" != "false" ]; then
    echo "INFRA-061 A: the bootstrap window is still open after the gate failed:" >&2
    cat "$log.out" >&2
    exit 1
  fi
fi
# DEC-040 discriminator: the base identity is valid but the provisioning role cannot be
# assumed. A cluster refusal then must NOT be read as de-escalation -- the run has to come
# back Undetermined and fail, or a broken credential passes as a verified removal. This is
# the end-to-end counterpart of the unit case, and it fails if the identity check is skipped.
# The positive pairing -- a refusal with a *working* identity counting as the removal -- is
# covered by the unit case (refusal_is_deescalation with Credential_assumable), because the
# emulated cluster's window bookkeeping does not line up for it end to end here.
sts_log="$tmp/sts-unassumable.log"
if (export FAIL_ON=""; export WHOAMI_REFUSE=1; export STS_ASSUME_FAIL=1; run_apply "$sts_log"); then
  echo "a refusal with an unassumable role was accepted as de-escalation:" >&2
  cat "$sts_log.out" >&2
  exit 1
fi
grep -qF 'could not be assumed' "$sts_log.out" || {
  echo "the run failed, but not because the role could not be assumed:" >&2
  cat "$sts_log.out" >&2
  exit 1
}

# DEC-040 transient: the same injected access failure, but it clears after the first
# attempt. The bounded retry must ride through it and the install must survive -- and the
# log must show the retry, because otherwise "survived" is indistinguishable from "the
# injection never happened", which is how a one-shot injection turns a fatal case into a
# false pass.
transient_log="$tmp/access-transient.log"
rm -f "$tmp/markers/access"
if ! (export FAIL_ON=access; export ACCESS_FAIL=once; run_apply "$transient_log"); then
  echo "a transient access failure failed the run instead of being retried through:" >&2
  cat "$transient_log.out" >&2
  exit 1
fi
grep -qF 'not reachable yet' "$transient_log.out" || {
  echo "the run survived an injected access failure without ever retrying, so this scenario" >&2
  echo "did not exercise the retry path at all:" >&2
  cat "$transient_log.out" >&2
  exit 1
}

if ! (export FAIL_ON=""; run_apply "$log"); then
    cat "$log" >&2
    cat "$log.out" >&2
    echo "cloud apply did not resume after injected $phase failure" >&2
    exit 1
  fi
done

# DEC-040 tri-state. After de-escalation the capability probe must obtain a *usable*
# answer. A `kubectl auth can-i` that exits non-zero for a non-authorization reason -- an
# unreachable API here -- is not a denial, and reading it as one would declare the removal
# verified while the surface was never established. This is the fail-open the tri-state
# closes; it fails if the answer is classified by exit code instead of by stdout.
can_i_log="$tmp/can-i-indeterminate.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window"
if (export FAIL_ON=""; export CAN_I_FAIL=1; run_apply "$can_i_log"); then
  echo "a non-authorization can-i failure was accepted as de-escalation:" >&2
  cat "$can_i_log.out" >&2
  exit 1
fi
grep -qF 'no usable answer' "$can_i_log.out" || {
  echo "the run failed, but not because the capability probe was indeterminate:" >&2
  cat "$can_i_log.out" >&2
  exit 1
}

# INFRA-061 control strictness. One capability is indeterminate *inside the window* while
# the others are permitted. An indeterminate capability makes the later transition
# Undetermined regardless, so a control that accepts "any capability permitted" spends the
# platform install only to fail at de-escalation. The control must refuse the window, name
# the indeterminate probe, and stop before the platform install.
indeterminate_window_log="$tmp/window-indeterminate.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window"
if (export FAIL_ON=""; export CAN_I_INDETERMINATE_WHEN_OPEN=1; run_apply "$indeterminate_window_log"); then
  echo "an indeterminate window probe did not stop the run:" >&2
  cat "$indeterminate_window_log.out" >&2
  exit 1
fi
grep -qF 'indeterminate probe' "$indeterminate_window_log.out" || {
  echo "the run did not report why the window could not be established:" >&2
  cat "$indeterminate_window_log.out" >&2
  exit 1
}
if grep -qF 'platform-apply' "$indeterminate_window_log.out"; then
  echo "the run reached the platform install despite an indeterminate window probe:" >&2
  cat "$indeterminate_window_log.out" >&2
  exit 1
fi
if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null || true)" != "false" ]; then
  echo "the indeterminate-window failure left the bootstrap window open:" >&2
  cat "$indeterminate_window_log.out" >&2
  exit 1
fi

# INFRA-034: a transient unmet readiness sample must be waited out, not fatal. This
# is the defect a real target hit: every component is still starting the moment the
# platform apply returns, so a one-shot check failed a healthy install.
rm -f "$tmp/markers/readiness"
log="$tmp/readiness-transient.log"
if ! (export FAIL_ON=readiness; run_apply "$log"); then
  cat "$log.out" >&2
  echo "a transient unmet readiness sample failed the install instead of being waited out" >&2
  exit 1
fi
grep -F 'awaiting platform readiness' "$log.out" >/dev/null || {
  echo "an unmet readiness sample was not reported while waiting:" >&2
  cat "$log.out" >&2
  exit 1
}
grep -F 'lifecycle phase: Ready' "$log.out" >/dev/null || {
  echo "the install did not reach Ready after a transient unmet readiness sample:" >&2
  cat "$log.out" >&2
  exit 1
}

# ...and the other end: a platform that never converges must still fail closed,
# within the bounded deadline (which is overridable so this stays fast).
log="$tmp/readiness-persistent.log"
if (export FAIL_READINESS_ALWAYS=1 SOL_PLATFORM_READINESS_TIMEOUT_S=0; run_apply "$log"); then
  echo "cloud apply succeeded although the platform never became ready" >&2
  exit 1
fi
grep -F 'platform readiness Unmet' "$log.out" >/dev/null || {
  echo "a never-ready platform did not report the unmet readiness summary:" >&2
  cat "$log.out" >&2
  exit 1
}

# The default StorageClass is the one readiness predicate that is the cloud
# provider's rather than Sol's -- which class is default, and which CSI driver
# backs it. A wrong answer must fail the install closed with that reason, rather
# than being inferred from the target's configuration (the class name appears in
# both the Terraform root and the readiness check, so "config says gp3" is not
# evidence that the cluster's default is gp3).
log="$tmp/storage-class-wrong.log"
if (export STORAGE_CLASS_WRONG=1 SOL_PLATFORM_READINESS_TIMEOUT_S=0; run_apply "$log"); then
  echo "cloud apply reached Ready although the default StorageClass was not the platform's" >&2
  cat "$log.out" >&2
  exit 1
fi
grep -F 'default StorageClass' "$log.out" >/dev/null || {
  echo "a wrong default StorageClass did not name the unmet check:" >&2
  cat "$log.out" >&2
  exit 1
}
grep -F 'ebs.csi.aws.com' "$log.out" >/dev/null || {
  echo "the unmet storage check did not name the driver the platform requires:" >&2
  cat "$log.out" >&2
  exit 1
}
# The install must not de-escalate into Ready on the way out: the same fail-closed
# rule as any other unmet readiness check.
if grep -F 'lifecycle phase: Ready' "$log.out" >/dev/null; then
  echo "a wrong default StorageClass still reported Ready:" >&2
  cat "$log.out" >&2
  exit 1
fi

log="$tmp/success.log"
(export FAIL_ON=""; run_apply "$log")
grep -F 'key=sol/prod/aws/us-east-1/cloud.tfstate' "$log" >/dev/null
grep -F 'key=sol/prod/aws/us-east-1/platform.tfstate' "$log" >/dev/null
grep -F -- '-target=module.platform.helm_release.cert_manager' "$log" >/dev/null
grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* apply ' | grep -v -- '-target=' >/dev/null
# HARDEN-002 run 3, finding 11: the target's deploy_role_arn must be routed to
# the provider root (the AWS root declares it and uses it to create the deploy
# EKS access entry INFRA-025 added).
grep -F -- '-var=deploy_role_arn=arn:aws:iam::111122223333:role/sol-deploy' "$log" >/dev/null
# HARDEN-002 run 4, finding 12: the platform Terraform must be handed the
# ephemeral provisioner kubeconfig under the names the providers actually read.
grep -F 'env KUBE_CONFIG_PATH=' "$log" >/dev/null
grep -F 'env KUBE_CONFIG_PATHS=' "$log" >/dev/null
# ADR 0003 (findings 13/14): installing the platform is privileged platform
# establishment, so the full platform apply (the non-targeted base apply) must
# run while the temporary PlatformInstalling authority is still open -- i.e.
# before provisioner-bootstrap-access-remove -- and only then is it revoked.
full_apply_line="$(grep -nF 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* apply ' | grep -v -- '-target=' | head -1 | cut -d: -f1 || true)"
deescalate_line="$(grep -nF -- 'provisioner_bootstrap_admin=false' "$log" | head -1 | cut -d: -f1 || true)"
if [ -z "$full_apply_line" ] || [ -z "$deescalate_line" ] || [ "$full_apply_line" -ge "$deescalate_line" ]; then
  echo "the platform install must complete before provisioner de-escalation" >&2
  exit 1
fi
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

# ADR 0003 invariants 3 and 5: the phase a run enters is recomputed from
# observation, and a run may only leave it along an edge the transition relation
# admits. A first install enters PlatformInstalling; a re-apply of an
# already-installed target is the explicit privileged re-entry PlatformUpdating,
# never a silent return to PlatformInstalling -- which the relation rejects, so
# classifying it that way would have made the model and the operation disagree.
fresh_log="$tmp/phase-fresh.log"
rm -f "$PLATFORM_INSTALLED_FILE"
if ! (export FAIL_ON=""; export FRESH_TARGET=1; run_apply "$fresh_log"); then
  cat "$fresh_log" >&2
  cat "$fresh_log.out" >&2
  echo "cloud apply did not complete a first install" >&2
  exit 1
fi
grep -F 'lifecycle phase: PlatformInstalling' "$fresh_log.out" >/dev/null || {
  echo "a first install did not report PlatformInstalling:" >&2
  cat "$fresh_log.out" >&2
  exit 1
}
# INFRA-031: the run ends in Ready only after readiness is verified AND the
# privileged association is revoked AND the bounded provisioner is re-verified,
# so the phase an operator reads is the state the target is actually left in.
grep -F 'lifecycle phase: Ready' "$fresh_log.out" >/dev/null || {
  echo "a completed install did not report Ready:" >&2
  cat "$fresh_log.out" >&2
  exit 1
}

update_log="$tmp/phase-update.log"
if ! (export FAIL_ON=""; export FRESH_TARGET=1; run_apply "$update_log"); then
  cat "$update_log" >&2
  cat "$update_log.out" >&2
  echo "cloud apply did not complete a re-apply" >&2
  exit 1
fi
grep -F 'lifecycle phase: PlatformUpdating' "$update_log.out" >/dev/null || {
  echo "a re-apply of an installed target did not report PlatformUpdating:" >&2
  cat "$update_log.out" >&2
  exit 1
}
grep -F 'lifecycle phase: PlatformInstalling' "$update_log.out" >/dev/null && {
  echo "a re-apply of an installed target was misclassified as PlatformInstalling" >&2
  exit 1
}

# INFRA-031: a target whose cloud substrate does not exist yet reports
# CloudBootstrap *before* the privileged apply that creates it, rather than that
# first phase being visible only as the absence of output. The fixture models
# "no substrate yet" with OUTPUT_ABSENT=1, which also makes the run fail closed
# afterwards (an apply with no lifecycle outputs cannot continue) — so the phase
# is asserted against a run that does not silently appear to succeed.
bootstrap_log="$tmp/phase-bootstrap.log"
if (export OUTPUT_ABSENT=1; run_apply "$bootstrap_log"); then
  echo "an apply with no cloud substrate reported success and must not" >&2
  exit 1
fi
grep -F 'lifecycle phase: CloudBootstrap' "$bootstrap_log.out" >/dev/null || {
  echo "a target with no cloud substrate did not report CloudBootstrap:" >&2
  cat "$bootstrap_log.out" >&2
  exit 1
}

plan() {
  local log="$1"
  shift
  (cd "$tmp/work" && env LIFECYCLE_LOG="$log" "$@" "$sol" cloud plan prod/aws/us-east-1) \
    >"$log.out" 2>&1
}

# A plan may read state and the cluster, but it must never mutate anything to
# make a later phase plannable.
no_plan_mutation() {
  local log="$1"
  if grep -Eq 'terraform .*( apply | destroy )|kubectl (apply|delete|create|patch|replace|scale|annotate|label|set )|aws .*( create-| delete-| modify-| put-| terminate-| run-)' "$log"; then
    echo "cloud plan mutated or attempted a mutation:" >&2
    cat "$log" >&2
    exit 1
  fi
}

# Absent target: both platform phases Deferred, exit zero, nothing mutated.
log="$tmp/plan-absent.log"
if ! plan "$log" OUTPUT_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan on an absent target must exit zero with Deferred phases" >&2
  exit 1
fi
grep -F 'requires cloud substrate to exist' "$log.out" >/dev/null
no_plan_mutation "$log"

# Cluster exists but the provisioner's platform RBAC is not yet established:
# both platform phases Deferred because granting bootstrap access would mutate.
log="$tmp/plan-rbac.log"
if ! plan "$log" RBAC_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan before provisioner RBAC must exit zero with Deferred phases" >&2
  exit 1
fi
grep -F 'requires provisioner platform RBAC established by an earlier apply' "$log.out" >/dev/null
if grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* plan ' >/dev/null; then
  echo "cloud plan planned the platform before its provisioner RBAC existed" >&2
  exit 1
fi
no_plan_mutation "$log"

# The provisioner cannot authenticate to the cluster at all: unavailable
# authentication is non-zero, not a Deferred phase (same exit-1 from can-i).
log="$tmp/plan-auth.log"
if plan "$log" AUTH_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan must exit non-zero when the provisioner cannot authenticate" >&2
  exit 1
fi
grep -F 'could not authenticate to the cluster as the platform provisioner' "$log.out" >/dev/null
no_plan_mutation "$log"

# Cluster and RBAC established, CRDs not yet: prerequisites are plannable and
# the CRD-dependent substrate stays Deferred.
log="$tmp/plan-prereq.log"
if ! plan "$log" CRDS_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan with CRDs not established must exit zero with a Deferred substrate" >&2
  exit 1
fi
grep -F 'requires cert-manager CRDs to be Established' "$log.out" >/dev/null
grep -F -- '-target=module.platform.helm_release.cert_manager' "$log" >/dev/null
if grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* plan ' | grep -v -- '-target=' >/dev/null; then
  echo "cloud plan previewed CRD-dependent platform before its CRDs were Established" >&2
  exit 1
fi
no_plan_mutation "$log"

# Fully established: both phases planned, nothing Deferred.
log="$tmp/plan-full.log"
if ! plan "$log"; then
  cat "$log.out" >&2
  echo "cloud plan on an established target must exit zero" >&2
  exit 1
fi
grep -F -- '-target=module.platform.helm_release.cert_manager' "$log" >/dev/null
grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* plan ' | grep -v -- '-target=' >/dev/null
if grep -F 'DEFERRED' "$log.out" >/dev/null; then
  echo "cloud plan deferred a phase on a fully established target" >&2
  exit 1
fi
no_plan_mutation "$log"

# A plannable-phase failure is non-zero, not silently Deferred.
log="$tmp/plan-fail.log"
rm -f "$tmp/markers/plan"

# INFRA-039: credentials that cannot be resolved must stop the operation before it
# mutates anything, and say so in terms an operator can act on. The direction of
# the failure is the point: an operation that cannot authenticate must not be
# discovered half-way through, and a destroy must say the target is still standing.
cred_log="$tmp/credentials.log"
if (export FAIL_CREDENTIALS=1; run_apply "$cred_log"); then
  echo "credential failure: apply survived unresolvable credentials" >&2
  exit 1
fi
assert_contains "credentials named the operation" "$cred_log.out" \
  'cannot resolve AWS credentials before applying' || {
  echo "credential failure: the error does not name the operation:" >&2
  cat "$cred_log.out" >&2
  exit 1
}
assert_contains "credentials stated nothing changed" "$cred_log.out" \
  'Nothing has been changed' || {
  echo "credential failure: the error does not state that nothing was changed" >&2
  cat "$cred_log.out" >&2
  exit 1
}
assert_not_contains "no apply stage ran" "$cred_log.out" '[terraform-apply] ok' || {
  echo "credential failure: an apply stage ran despite unresolvable credentials" >&2
  exit 1
}

if plan "$log" FAIL_ON=plan; then
  cat "$log.out" >&2
  echo "cloud plan must exit non-zero when a plannable phase fails" >&2
  exit 1
fi

# Every ephemeral kubeconfig, including the plan runs', is removed.
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

# ── GCP ─────────────────────────────────────────────────────────────────────
#
# Sol used to refuse this at a provider gate. It now runs the same phases on GCP
# through the provider's own mechanisms, and what is assertable offline is the
# *orchestration*: which commands Sol issues, in what order, carrying which policy.
# Whether GKE or Cloud SQL honour them is what a live target answers.
gcp_log="$tmp/gcp-plan.log"
rm -f "$tmp/markers/gcp-prepare" "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if ! (cd "$tmp/work" && LIFECYCLE_LOG="$gcp_log" "$sol" cloud plan prod/gcp/us-central1) \
  >"$gcp_log.out" 2>&1
then
  cat "$gcp_log.out" >&2
  echo "cloud plan on GCP failed" >&2
  exit 1
fi
# The cluster credential is the provider's mechanism, into a file of Sol's own
# choosing -- never the ambient kubeconfig.
grep -F 'gcloud container clusters get-credentials sol-qual --region us-central1' "$gcp_log" \
  >/dev/null || {
  echo "GCP plan did not obtain cluster credentials through gcloud:" >&2
  grep -F 'gcloud ' "$gcp_log" >&2
  exit 1
}
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"
# The platform definition is reached through the GCP root and told which provider
# it is building for: an AWS variable there is an undeclared-variable error, not a
# no-op, so seeing one means the provider-shaped mapping regressed.
# The caller the target named must reach the root: Attempt 2's first live failure was
# that nothing granted the bootstrap caller the ability to impersonate the provisioner,
# because nothing declared one at all.
grep -F -- '-var=provisioner_impersonators=["user:qualification-operator@example.test"]' \
  "$gcp_log" >/dev/null || {
  echo "the target's declared provisioner_impersonator did not reach the GCP root:" >&2
  grep -F 'provisioner_impersonators' "$gcp_log" >&2
  exit 1
}
# ...and it is *only* the declared one: an inferred member would satisfy "impersonation
# works" while granting authority to whoever ran Sol.
if grep -F -- '-var=provisioner_impersonators=[' "$gcp_log" | grep -vF 'qualification-operator@example.test' >/dev/null; then
  echo "the impersonation grant named a member the target did not declare:" >&2
  grep -F 'provisioner_impersonators' "$gcp_log" >&2
  exit 1
fi
grep -F -- '-var=cloud_provider=gcp' "$gcp_log" >/dev/null || {
  echo "the GCP platform root was not told cloud_provider=gcp:" >&2
  grep -F 'platform/cloud/' "$gcp_log" >&2
  exit 1
}
for aws_only in aws_region= cert_manager_irsa_role_arn= loki_s3_bucket= \
  provisioner_bootstrap_admin create_rds= rds_multi_az= ecr_repositories= workspace_name=; do
  if grep -F -- "-var=$aws_only" "$gcp_log" >/dev/null; then
    echo "an AWS variable ($aws_only) reached the GCP root:" >&2
    exit 1
  fi
done

# Destroy on GCP. Both deletion guards are lifted by an applied transition on the
# guarded resources (never by a `-var` on the destroy, which is inert against prior
# state), must stay lifted for the reconciliation apply that precedes the teardown,
# and the teardown is then verified absent through the provider's own API.
gcp_destroy_log="$tmp/gcp-destroy.log"
if ! (cd "$tmp/work" && DESTROYING=1 LIFECYCLE_LOG="$gcp_destroy_log" \
        "$sol" cloud destroy prod/gcp/us-central1 --apply) \
  >"$gcp_destroy_log.out" 2>&1
then
  cat "$gcp_destroy_log.out" >&2
  echo "cloud destroy on GCP failed" >&2
  exit 1
fi
grep -E -- '-chdir=[^ ]*cloud/gcp/cluster ' "$gcp_destroy_log" \
  | grep -F -- '-target=google_sql_database_instance.postgres' \
  | grep -F -- '-var=sql_deletion_protection=false' >/dev/null || {
  echo "GCP destroy did not lift Cloud SQL's guard through a targeted apply:" >&2
  grep -F 'cloud/gcp/cluster' "$gcp_destroy_log" >&2
  exit 1
}
grep -F 'verify preparation: Cloud SQL and GKE deletion protection disabled' \
  "$gcp_destroy_log.out" >/dev/null || {
  echo "GCP destroy did not verify that the preparation landed:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
}
for override in sql_deletion_protection=false gke_deletion_protection=false; do
  grep -E -- '-chdir=[^ ]*cloud/gcp/cluster ' "$gcp_destroy_log" \
    | grep -F ' destroy ' \
    | grep -F -- "-var=$override" >/dev/null || {
    echo "the GCP destroy did not carry the Destroy policy's $override override:" >&2
    grep -E ' destroy ' "$gcp_destroy_log" >&2
    exit 1
  }
done
# FND-0058 / INFRA-079: the authority mechanism's plan change is instance-qualified
# (above), the acquisition is plan-asserted and permitted, and the order is the one
# the destroy policy describes -- acquire, protect, release, then the substrate. The
# fixture carrying `[0]` is what makes this a regression test: with an
# instance-blind declaration the reconciliation is refused and the protected step
# never runs, so the line-order assertions below cannot all hold.
# `|| true` on each: the point of the checks below is to say *which* phase never
# ran, and a pipeline under `set -o pipefail` would otherwise abort the suite
# silently the moment a grep found nothing.
authority_line="$(grep -n -- '-var=provisioner_bootstrap_admin=true' "$gcp_destroy_log" | head -1 | cut -d: -f1 || true)"
platform_destroy_line="$(grep -nE -- '^terraform -chdir=[^ ]*cloud/gcp/platform destroy ' "$gcp_destroy_log" | head -1 | cut -d: -f1 || true)"
release_line="$(grep -n -- '-var=provisioner_bootstrap_admin=false' "$gcp_destroy_log" | head -1 | cut -d: -f1 || true)"
substrate_destroy_line="$(grep -nE -- '^terraform -chdir=[^ ]*cloud/gcp/cluster destroy ' "$gcp_destroy_log" | head -1 | cut -d: -f1 || true)"
for phase in "authority acquisition:authority_line" \
  "platform teardown:platform_destroy_line" \
  "authority release:release_line" \
  "substrate destroy:substrate_destroy_line"; do
  label="${phase%%:*}"
  variable="${phase##*:}"
  if [ -z "$(eval printf '%s' "\$$variable")" ]; then
    echo "the destroy never reached the $label (no such command in the lifecycle log):" >&2
    grep -nE -- 'terraform|refused|degrad' "$gcp_destroy_log" >&2 || true
    exit 1
  fi
done
if [ "$authority_line" -ge "$platform_destroy_line" ] ||
   [ "$platform_destroy_line" -ge "$release_line" ] ||
   [ "$release_line" -ge "$substrate_destroy_line" ]; then
  echo "the destroy ran its phases out of order: acquire=$authority_line platform=$platform_destroy_line release=$release_line substrate=$substrate_destroy_line" >&2
  exit 1
fi
if grep -F 'refused before apply' "$gcp_destroy_log.out" >/dev/null; then
  echo "the destroy refused its own permitted authority create:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi
if grep -F 'a preparation degraded and destruction continued' "$gcp_destroy_log.out" >/dev/null; then
  echo "the destroy degraded although its authority acquisition was permitted:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi

# HARDEN-004 step 5, narrowed by DEC-045 / REFAC-094: Terraform's destroy plus an
# empty state is the authority for what Terraform manages, so the report states the
# state postcondition and the residue Terraform does not own -- and the provider is
# not asked, resource by resource, about what Terraform just destroyed.
assert_contains "the GCP destroy read its own state postcondition" "$gcp_destroy_log.out" \
  'terraform state (disposable root): empty -- Terraform destroyed every resource it manages' || exit 1
assert_contains "the GCP residue check ran and found nothing" "$gcp_destroy_log.out" \
  'residue Terraform does not own (controller load balancers, PVC volumes, abandoned peering): none found' || exit 1
# Positive control for the negative below: the peering residue query is recorded in
# the same log.
grep -F 'gcloud services vpc-peerings list' "$gcp_destroy_log" >/dev/null || {
  echo "REFAC-094: the GCP residue (peering) query is missing from the destroy log" >&2
  exit 1
}
for managed in 'gcloud container clusters describe' 'gcloud sql instances describe' \
               'gcloud compute networks describe' 'gcloud artifacts repositories describe' \
               'gcloud compute addresses describe'; do
  if grep -F "$managed" "$gcp_destroy_log" >/dev/null; then
    echo "REFAC-094: the GCP destroy still re-queries a Terraform-managed resource: $managed" >&2
    exit 1
  fi
done
grep -F 'retention: none' "$gcp_destroy_log.out" >/dev/null || {
  echo "the GCP destroy did not say what it kept:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
}
# FND-0046: the old report claimed "no residual billable artifacts" from the policy
# alone. GCP has no snapshot surface to observe, and the report has to say that
# rather than assert an absence nothing checked.
assert_contains "the GCP retention claim names what was actually checked" "$gcp_destroy_log.out" \
  'there is no GCP snapshot surface to observe' || exit 1
assert_contains "INFRA-077: the GCP none claim names the soft-delete setting" "$gcp_destroy_log.out" \
  'observability buckets were created with soft delete off' || exit 1
if grep -F 'no residual billable artifacts' "$gcp_destroy_log.out" >/dev/null; then
  echo "the GCP destroy claimed no residual billable artifacts, which nothing observed:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi
# INFRA-039's guarantee applies to GCP too, through GCP's own credential: a mutating
# stage resolves it rather than assuming it inherited a working environment.
grep -F 'gcloud auth application-default print-access-token' "$gcp_destroy_log" >/dev/null || {
  echo "GCP did not resolve its credentials through the provider's mechanism:" >&2
  grep -F 'gcloud ' "$gcp_destroy_log" >&2
  exit 1
}
grep -F 'credentials: Google Application Default Credentials resolved' \
  "$gcp_destroy_log.out" >/dev/null || {
  echo "the GCP destroy did not report the credentials it resolved:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
}

# HARDEN-004 steps 3 + 4, the governing invariant end to end: a reconciliation plan
# that would reconstruct the missing cluster (a target-owned CREATE) is refused
# *before* its apply -- and the refusal is an outcome, not a refusal of the destroy.
# Step 4: the protected platform teardown cannot run without the authority, so it is
# skipped, but the substrate destroy does run -- stranding a half-built target is the
# failure this whole path exists to remove. The run reaches absence, says what
# degraded, and exits 0 (REFAC-094: the degradation is a warning, not an exit code).
refuse_log="$tmp/gcp-refuse.log"
rm -f "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE" "$FAIL_MARKER_DIR/bootstrap-window"
refuse_rc=0
(cd "$tmp/work" && PLAN_CREATES_MISSING_CLUSTER=1 DESTROYING=1 \
   LIFECYCLE_LOG="$refuse_log" "$sol" cloud destroy prod/gcp/us-central1 --apply) \
  >"$refuse_log.out" 2>&1 || refuse_rc=$?
if [ "$refuse_rc" -ne 0 ]; then
  echo "a destroy that reached absence with a degraded preparation must exit 0, not $refuse_rc:" >&2
  cat "$refuse_log.out" >&2
  exit 1
fi
grep -F 'refused before apply' "$refuse_log.out" >/dev/null || {
  echo "the refused plan was not the reason the reconciliation did not run:" >&2
  cat "$refuse_log.out" >&2
  exit 1
}
grep -F 'a preparation degraded and destruction continued' "$refuse_log.out" >/dev/null || {
  echo "the degradation was not reported:" >&2
  cat "$refuse_log.out" >&2
  exit 1
}
# The refused apply never ran (the stub exits 99 if it did), and the substrate destroy
# -- the step that removes billable infrastructure -- did.
if ! grep -E -- '-chdir=[^ ]*cloud/gcp/cluster ' "$refuse_log" | grep -F ' destroy ' >/dev/null; then
  echo "the substrate destroy did not run after a refused reconciliation:" >&2
  cat "$refuse_log" >&2
  exit 1
fi
if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null)" != "false" ]; then
  echo "the bootstrap window was not removed after the refused reconciliation:" >&2
  grep -nE 'bootstrap|refused' "$refuse_log" >&2 || true
  exit 1
fi

# INFRA-070 / FND-0047: on GCP a failed `get-credentials` exits the lifecycle. It used to
# do so without running the caller's cleanup (`with_cluster_access` ignored `on_error` on
# GCP), which left the provisioner elevated after the destroy's reconciliation apply had
# opened the bootstrap window. The window must be closed -- an apply with
# provisioner_bootstrap_admin=false after the failed get-credentials -- before exit.
gcp_access_log="$tmp/gcp-access-failure.log"
rm -f "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE" "$FAIL_MARKER_DIR/access" \
  "$FAIL_MARKER_DIR/bootstrap-window"
if (cd "$tmp/work" && FAIL_ON=access DESTROYING=1 LIFECYCLE_LOG="$gcp_access_log" \
      "$sol" cloud destroy prod/gcp/us-central1 --apply) \
  >"$gcp_access_log.out" 2>&1
then
  cat "$gcp_access_log.out" >&2
  echo "GCP destroy succeeded although cluster access could not be established" >&2
  exit 1
fi
grep -F 'could not establish ephemeral cluster access' "$gcp_access_log.out" >/dev/null || {
  echo "the injected get-credentials failure was not the reason the GCP destroy stopped:" >&2
  cat "$gcp_access_log.out" >&2
  exit 1
}
access_line="$(grep -nF 'get-credentials' "$gcp_access_log" | tail -1 | cut -d: -f1 || true)"
# HARDEN-004 step 3: the window is closed by a planned, asserted apply, so the
# variable is on the plan line and the apply is the saved plan. The stub writes
# the window marker on the apply, so asserting it proves the closing apply ran --
# not merely that it was planned.
close_plan_line="$(grep -nE -- '-chdir=[^ ]*cloud/gcp/cluster plan ' "$gcp_access_log" \
  | grep -F -- 'provisioner_bootstrap_admin=false' | tail -1 | cut -d: -f1 || true)"
if [ -z "$access_line" ] || [ -z "$close_plan_line" ] || [ "$close_plan_line" -le "$access_line" ]; then
  echo "a GCP cluster-access failure exited without closing the bootstrap window:" >&2
  grep -nE 'get-credentials|provisioner_bootstrap_admin' "$gcp_access_log" >&2 || true
  exit 1
fi
if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null)" != "false" ]; then
  echo "the bootstrap window was not closed by an apply after the failed get-credentials:" >&2
  grep -nE 'get-credentials|provisioner_bootstrap_admin' "$gcp_access_log" >&2 || true
  exit 1
fi

# The install path hands the same cleanup to the same helper (`cloud apply` opens the
# bootstrap window before it needs cluster access), so it gets the same assertion.
gcp_apply_access_log="$tmp/gcp-apply-access-failure.log"
rm -f "$FAIL_MARKER_DIR/access"
if (cd "$tmp/work" && FAIL_ON=access LIFECYCLE_LOG="$gcp_apply_access_log" \
      "$sol" cloud apply prod/gcp/us-central1) \
  >"$gcp_apply_access_log.out" 2>&1
then
  cat "$gcp_apply_access_log.out" >&2
  echo "GCP apply succeeded although cluster access could not be established" >&2
  exit 1
fi
grep -F 'could not establish ephemeral cluster access' "$gcp_apply_access_log.out" \
  >/dev/null || {
  echo "the injected get-credentials failure was not the reason the GCP apply stopped:" >&2
  cat "$gcp_apply_access_log.out" >&2
  exit 1
}
access_line="$(grep -nF 'get-credentials' "$gcp_apply_access_log" | tail -1 | cut -d: -f1 || true)"
close_line="$(grep -nE -- '-chdir=[^ ]*cloud/gcp/cluster apply ' "$gcp_apply_access_log" \
  | grep -F -- 'provisioner_bootstrap_admin=false' | tail -1 | cut -d: -f1 || true)"
if [ -z "$access_line" ] || [ -z "$close_line" ] || [ "$close_line" -le "$access_line" ]; then
  echo "a GCP cluster-access failure during apply exited without closing the bootstrap window:" >&2
  grep -nE 'get-credentials|provisioner_bootstrap_admin' "$gcp_apply_access_log" >&2 || true
  exit 1
fi

# INFRA-074 / FND-0043: `sol cloud apply` plans to a file and reads it first. A plan
# that deletes an ECR repository (and with it every image) is refused before
# anything changes, unless --confirm-ecr-removal is given. What is applied is the
# plan that was read.
ecr_log="$tmp/ecr-removal.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window"
if (export FAIL_ON=""; export ECR_REMOVAL=1; run_apply "$ecr_log"); then
  cat "$ecr_log.out" >&2
  echo "cloud apply went ahead with a plan that deletes an ECR repository" >&2
  exit 1
fi
grep -F 'would delete' "$ecr_log.out" >/dev/null || {
  echo "the ECR refusal did not say what it refused:" >&2
  cat "$ecr_log.out" >&2
  exit 1
}
grep -F 'what a re-apply cannot restore' "$ecr_log.out" >/dev/null || {
  echo "the refusal did not say why it refused:" >&2
  cat "$ecr_log.out" >&2
  exit 1
}
grep -F -- '--confirm-ecr-removal' "$ecr_log.out" >/dev/null || {
  echo "the refusal did not name the flag that confirms it:" >&2
  cat "$ecr_log.out" >&2
  exit 1
}
grep -F 'old-svc' "$ecr_log.out" >/dev/null || {
  echo "the ECR refusal did not name the repository:" >&2
  cat "$ecr_log.out" >&2
  exit 1
}
if grep -E -- '-chdir=[^ ]*cloud/aws/cluster apply ' "$ecr_log" >/dev/null; then
  echo "a refused cloud apply still ran terraform apply:" >&2
  grep -E ' apply ' "$ecr_log" >&2
  exit 1
fi
ecr_confirmed_log="$tmp/ecr-removal-confirmed.log"
if ! (cd "$tmp/work" && FAIL_ON="" ECR_REMOVAL=1 LIFECYCLE_LOG="$ecr_confirmed_log" \
        "$sol" cloud apply prod/aws/us-east-1 --confirm-ecr-removal) \
  >"$ecr_confirmed_log.out" 2>&1
then
  cat "$ecr_confirmed_log.out" >&2
  echo "a confirmed ECR removal was refused" >&2
  exit 1
fi
grep -E -- '-chdir=[^ ]*cloud/aws/cluster apply .*\.tfplan' "$ecr_confirmed_log" >/dev/null || {
  echo "the confirmed cloud apply did not apply the saved plan it read:" >&2
  grep -E ' apply ' "$ecr_confirmed_log" >&2
  exit 1
}

# Attempt 3 spent a billable apply before discovering that the host lacked the
# plugin the platform stage needs. It must be refused up front instead -- the check
# costs nothing and the alternative costs an apply.
gcp_toolchain_log="$tmp/gcp-toolchain.log"
rm -f "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if (cd "$tmp/work" && NO_AUTH_PLUGIN=1 DESTROYING=1 LIFECYCLE_LOG="$gcp_toolchain_log" \
      "$sol" cloud destroy prod/gcp/us-central1 --apply) \
  >"$gcp_toolchain_log.out" 2>&1
then
  echo "a GCP platform stage ran without gke-gcloud-auth-plugin" >&2
  exit 1
fi
grep -F 'gke-gcloud-auth-plugin' "$gcp_toolchain_log.out" >/dev/null || {
  echo "the missing-plugin failure did not name the plugin:" >&2
  cat "$gcp_toolchain_log.out" >&2
  exit 1
}
if grep -F 'platform-destroy' "$gcp_toolchain_log" >/dev/null; then
  echo "the missing-plugin failure reached the platform stage anyway:" >&2
  exit 1
fi

# ── INFRA-042: a partially installed platform must still be destroyable ─────
#
# Attempt 3's install failed partway, leaving the platform root's state holding
# CRD-backed resources (the two cert-manager ClusterIssuers) whose CRDs were never
# installed. Terraform cannot delete a resource whose API does not exist, so the
# documented destroy failed and the cloud layer stayed billable.
#
# This reproduces that and pins the intended recovery -- and, just as importantly,
# its limit: a resource whose kind the cluster *does* serve is never forgotten.
partial_log="$tmp/gcp-partial.log"
rm -f "$STATE_RM_FILE" "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if ! (cd "$tmp/work" && PARTIAL_INSTALL=1 DESTROYING=1 LIFECYCLE_LOG="$partial_log" \
        "$sol" cloud destroy prod/gcp/us-central1 --apply) \
  >"$partial_log.out" 2>&1
then
  # The first platform destroy fails (that is the reproduction); the recovery must
  # then have made the destroy succeed, so reaching here at all is a failure --
  # unless the CRD turned out to be served, which the negative case below covers.
  cat "$partial_log.out" >&2
  echo "INFRA-042: a partially installed platform was not destroyable" >&2
  exit 1
fi
# The failure was reached and observed, not skipped: the platform destroy really did
# run and really did fail before the recovery.
grep -F 'platform-destroy' "$partial_log.out" >/dev/null || {
  echo "INFRA-042: the platform destroy stage never ran" >&2
  exit 1
}
grep -F 'platform-destroy-retry' "$partial_log.out" >/dev/null || {
  echo "INFRA-042: the destroy was not retried after the recovery" >&2
  exit 1
}
# Exactly the unserved resource was forgotten -- by address, and only it.
grep -F 'state-rm module.platform.kubernetes_manifest.letsencrypt_prod' "$partial_log" \
  >/dev/null || {
  echo "INFRA-042: the unserved resource was not the one forgotten:" >&2
  grep -F 'state-rm' "$partial_log" >&2
  exit 1
}
if grep -F 'state-rm module.platform.kubernetes_namespace.cert_manager' "$partial_log" >/dev/null; then
  echo "INFRA-042: a resource whose kind the cluster serves was forgotten too" >&2
  exit 1
fi
grep -F 'CLUSTER DOES NOT SERVE' "$partial_log.out" >/dev/null || true
grep -F 'ClusterIssuer is not served by this cluster' "$partial_log.out" >/dev/null || {
  echo "INFRA-042: the recovery did not say which kind proved the resource absent:" >&2
  cat "$partial_log.out" >&2
  exit 1
}
# ...and the lifecycle still ends where it must.
assert_contains "INFRA-042: the destroy completed after the recovery" "$partial_log.out" \
  'terraform state (disposable root): empty' || {
  echo "INFRA-042: the destroy did not complete after the recovery:" >&2
  cat "$partial_log.out" >&2
  exit 1
}

# The limit: when the cluster *does* serve the kind, the resource may exist, so
# nothing is forgotten and the failure stands. This is the case that separates the
# recovery from "delete whatever Terraform cannot handle".
served_log="$tmp/gcp-partial-served.log"
rm -f "$STATE_RM_FILE"
if (cd "$tmp/work" && PARTIAL_INSTALL=1 CRD_SERVED=1 DESTROYING=1 \
      LIFECYCLE_LOG="$served_log" "$sol" cloud destroy prod/gcp/us-central1 --apply) \
  >"$served_log.out" 2>&1
then
  echo "INFRA-042: a destroy that could not delete a served resource reported success" >&2
  exit 1
fi
if grep -F 'state-rm' "$served_log" >/dev/null; then
  echo "INFRA-042: a resource whose kind the cluster serves was forgotten anyway:" >&2
  grep -F 'state-rm' "$served_log" >&2
  exit 1
fi
grep -F 'Could not remove Service Networking Connection\|API did not recognize' \
  "$served_log.out" >/dev/null || true
rm -f "$STATE_RM_FILE"

# ...and when they cannot be resolved, it fails closed and says the part that
# matters, rather than proceeding to mutate infrastructure it cannot authenticate
# against. This is the GCP half of INFRA-039's scenario.
gcp_nocred_log="$tmp/gcp-nocred.log"
if (cd "$tmp/work" && DESTROYING=1 FAIL_CREDENTIALS=1 LIFECYCLE_LOG="$gcp_nocred_log" \
      "$sol" cloud destroy prod/gcp/us-central1 --apply) \
  >"$gcp_nocred_log.out" 2>&1
then
  echo "a GCP destroy with unresolvable credentials proceeded instead of failing closed" >&2
  exit 1
fi
grep -F 'still standing and may still be billing' "$gcp_nocred_log.out" >/dev/null || {
  echo "the GCP credential failure did not say the target may still be billing:" >&2
  cat "$gcp_nocred_log.out" >&2
  exit 1
}
if grep -F 'cloud/gcp/cluster' "$gcp_nocred_log" | grep -F ' destroy ' >/dev/null; then
  echo "a GCP destroy with unresolvable credentials reached terraform anyway:" >&2
  exit 1
fi
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

# HARDEN-002 finding 9b: destroy must disable RDS deletion protection through
# a real applied transition (a targeted apply on just the RDS resource), with
# a snapshot identity unique to this attempt -- never by passing `-var` to
# `terraform destroy`, which is inert against a resource's prior state.
rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-established.log"
if ! run_destroy "$log"; then
  cat "$log.out" >&2
  echo "cloud destroy on an established target must succeed" >&2
  exit 1
fi
grep -F -- '-target=aws_db_instance.postgres' "$log" | grep -F 'rds_deletion_protection=false' \
  | grep -F 'rds_skip_final_snapshot=false' >/dev/null
snapshot_line="$(grep -F -- '-target=aws_db_instance.postgres' "$log" | head -1)"
snapshot_id="$(printf '%s\n' "$snapshot_line" | grep -oE 'rds_final_snapshot_identifier=[^ ]+' | cut -d= -f2)"
case "$snapshot_id" in
  lifecycle-test-postgres-final-*) : ;;
  *)
    echo "RDS final snapshot identifier was not the expected unique per-attempt name: $snapshot_id" >&2
    exit 1
    ;;
esac
grep -F 'verify preparation: RDS deletion protection disabled' "$log.out" >/dev/null
grep -F "final snapshot $snapshot_id confirmed" "$log.out" >/dev/null
# INFRA-047 / REFAC-093: the sweep queries what Terraform does not own -- EBS
# volumes created for PersistentVolumeClaims (and controller load balancers) --
# and a missing check cannot pass merely because the mock defaults to empty output.
grep -F 'aws ec2 describe-volumes' "$log" >/dev/null
# DEC-045: elastic IPs, NAT gateways and ECR repositories are Terraform-managed, so
# the destroy plus the empty-state check is their authority and the sweep must not
# query them. The describe-volumes line above is the positive control that this log
# records the sweep's queries at all.
for gone in 'aws ec2 describe-addresses' 'aws ec2 describe-nat-gateways' 'aws ecr describe-repositories'; do
  if grep -F "$gone" "$log" >/dev/null; then
    echo "REFAC-093: the destroy sweep still queries a Terraform-managed kind: $gone" >&2
    exit 1
  fi
done

# Mutation direction: a positive result must fail the public destroy command and
# identify the residual class.
for residual in ebs; do
  residual_log="$tmp/destroy-residual-$residual.log"
  if (export AWS_RESIDUAL_KIND="$residual"; run_destroy "$residual_log"); then
    echo "AWS destroy verification accepted residual $residual infrastructure" >&2
    exit 1
  fi
  case "$residual" in
    ebs) expected='AWS EBS volumes still exist after destroy' ;;
  esac
  grep -F "$expected" "$residual_log.out" >/dev/null || {
    echo "AWS residual $residual did not report its failed absence check" >&2
    cat "$residual_log.out" >&2
    exit 1
  }
done
# Preparation happens before the actual destroy, not folded into it.
prepare_line_no="$(grep -n -- '-target=aws_db_instance.postgres' "$log" | head -1 | cut -d: -f1)"
destroy_line_no="$(grep -n 'cloud/aws/cluster.* destroy ' "$log" | head -1 | cut -d: -f1)"
if [ -z "$destroy_line_no" ] || [ "$prepare_line_no" -ge "$destroy_line_no" ]; then
  echo "RDS destroy preparation did not run before the cloud destroy" >&2
  cat "$log" >&2
  exit 1
fi

# ADR 0003 / HARDEN-002 run 4 finding 15: after a verified PrepareDestroy the
# Destroy policy governs. The bootstrap-admin reconciliation that necessarily
# precedes the actual destroy must therefore still carry the destroy overrides,
# and they must be appended AFTER the production profile's
# rds_deletion_protection=true (injected by terraform_vars) so the Destroy policy
# wins rather than Ready policy silently re-enabling protection.
#
# HARDEN-004 step 3: the variables are carried by the *plan* the reconciliation is
# asserted from, and the apply is that saved plan.
admin_plan_line="$(grep 'cloud/aws/cluster.* plan ' "$log" | grep -F 'provisioner_bootstrap_admin=true' | head -1 || true)"
case "$admin_plan_line" in
  *'rds_deletion_protection=false'*) : ;;
  *)
    echo "the post-prepare bootstrap-admin apply did not carry the Destroy policy" >&2
    cat "$log" >&2
    exit 1
    ;;
esac
last_protection="$(printf '%s\n' "$admin_plan_line" | grep -oE 'rds_deletion_protection=[a-z]+' | tail -1)"
if [ "$last_protection" != "rds_deletion_protection=false" ]; then
  echo "Ready policy overrode the Destroy policy after PrepareDestroy ($last_protection)" >&2
  cat "$log" >&2
  exit 1
fi

# A second destroy attempt (e.g. retried after a prior failure elsewhere in
# the lifecycle) must mint a different snapshot identity, not reuse the
# cluster-derived constant HARDEN-002 finding 9b replaced.
log2="$tmp/destroy-established-2.log"
if ! run_destroy "$log2"; then
  cat "$log2.out" >&2
  echo "a second cloud destroy attempt must also succeed" >&2
  exit 1
fi
snapshot_line2="$(grep -F -- '-target=aws_db_instance.postgres' "$log2" | head -1)"
snapshot_id2="$(printf '%s\n' "$snapshot_line2" | grep -oE 'rds_final_snapshot_identifier=[^ ]+' | cut -d= -f2)"
if [ "$snapshot_id" = "$snapshot_id2" ]; then
  echo "two destroy attempts minted the same RDS final snapshot identifier: $snapshot_id" >&2
  exit 1
fi

# DEC-033 / INFRA-041: retention is whatever the target says, and the destroy
# reports it. This crosses parse -> merge -> destroy -> phase policy -> prepare ->
# post-prepare verification, which is the boundary the original DEC-033 tests did
# not cross: they exercised the model, and `merge_target` discarded the setting.
log_retain="$tmp/destroy-retention-default.log"
if ! run_destroy "$log_retain"; then
  cat "$log_retain.out" >&2
  echo "a default destroy must still succeed" >&2
  exit 1
fi
retain_line="$(grep -F -- '-target=aws_db_instance.postgres' "$log_retain" | head -1)"
case "$retain_line" in
  *'rds_skip_final_snapshot=false'*) : ;;
  *)
    echo "the default destroy did not retain the final snapshot; prepare saw: $retain_line" >&2
    exit 1
    ;;
esac
assert_contains "the default destroy reports what it retained" "$log_retain.out" \
  'retention: final snapshot' || exit 1
# HARDEN-004 step 5 / FND-0046: the retention claim is now an observation. The
# report has to name the identifier the preparation established *before* destroy and
# the state the provider says it reached -- not just the policy that was configured.
retained_id="$(printf '%s\n' "$retain_line" | grep -oE 'rds_final_snapshot_identifier=[^ ]+' | cut -d= -f2)"
if [ -z "$retained_id" ]; then
  echo "the default destroy did not name a final snapshot identifier:" >&2
  cat "$log_retain.out" >&2
  exit 1
fi
assert_contains "the retained snapshot was observed, not assumed" "$log_retain.out" \
  "final snapshot $retained_id observed available" || exit 1
assert_contains "the retention observation names how to remove it" "$log_retain.out" \
  'delete-db-snapshot' || exit 1
# DEC-045 / REFAC-094: the database and cluster Terraform destroyed are not re-queried;
# the retained final snapshot is (above), because Terraform does not own it.
assert_not_contains "the destroy does not re-query the Terraform-managed database" "$log_retain.out" \
  'aws rds describe-db-instances' || exit 1
assert_not_contains "the destroy does not re-query the Terraform-managed cluster" "$log_retain.out" \
  'aws eks describe-cluster' || exit 1

# HARDEN-004 step 5 / INFRA-072: retention is observed, so each way the observation
# can fail must fail the command. Separate runs, so short-circuiting one into
# another is observable rather than inferred.
missing_snapshot_log="$tmp/destroy-retention-missing.log"
rm -f "$RDS_PREPARED_FILE"
if (export RDS_SNAPSHOT_MISSING=1; run_destroy "$missing_snapshot_log"); then
  echo "a destroy whose promised final snapshot does not exist must fail" >&2
  cat "$missing_snapshot_log.out" >&2
  exit 1
fi
assert_contains "the missing final snapshot was reported" "$missing_snapshot_log.out" \
  'final-snapshot NOT observed' || exit 1
assert_contains "the missing snapshot failure names the guarantee" "$missing_snapshot_log.out" \
  'the target declared it keeps its final snapshot' || exit 1
assert_contains "the missing snapshot is a violation, not a degradation" \
  "$missing_snapshot_log.out" 'the destruction postcondition is violated' || exit 1

pending_snapshot_log="$tmp/destroy-retention-pending.log"
rm -f "$RDS_PREPARED_FILE"
if (export RDS_SNAPSHOT_PENDING=1 SOL_DESTROY_SNAPSHOT_INTERVAL_S=0; run_destroy "$pending_snapshot_log"); then
  echo "a destroy whose final snapshot never becomes available must fail" >&2
  cat "$pending_snapshot_log.out" >&2
  exit 1
fi
assert_contains "a snapshot still creating is not a met guarantee" "$pending_snapshot_log.out" \
  'the retention guarantee is not established while it has not reached available' || exit 1

# ...and the opposite direction: a snapshot the provider first reports as still being
# created and then as available must be *observed*, not abandoned. The fake says
# `creating` on the first read only, so a retry that did not happen would report
# UNKNOWN and fail this scenario.
creating_log="$tmp/destroy-retention-creating.log"
rm -f "$RDS_PREPARED_FILE" "$FAIL_MARKER_DIR/snapshot-creating"
if ! (export RDS_SNAPSHOT_CREATING_ONCE=1 SOL_DESTROY_SNAPSHOT_INTERVAL_S=0; \
      run_destroy "$creating_log"); then
  echo "a destroy whose final snapshot needed a second observation must succeed" >&2
  cat "$creating_log.out" >&2
  exit 1
fi
assert_contains "the promised snapshot was observed once it settled" "$creating_log.out" \
  'observed available' || exit 1

invalid_interval_log="$tmp/destroy-invalid-interval.log"
rm -f "$RDS_PREPARED_FILE" "$FAIL_MARKER_DIR/snapshot-creating"
if (export SOL_DESTROY_SNAPSHOT_INTERVAL_S=soon; run_destroy "$invalid_interval_log"); then
  echo "a destroy accepted an unparseable SOL_DESTROY_SNAPSHOT_INTERVAL_S" >&2
  exit 1
fi
assert_contains "an unparseable interval is refused, naming the variable" \
  "$invalid_interval_log.out" 'SOL_DESTROY_SNAPSHOT_INTERVAL_S' || exit 1

# The production guarantee must not be weakened by the new mode: a target that
# retains its snapshot still fails closed when the provider's record disagrees with
# what was prepared. The fake makes them disagree.
mismatch_log="$tmp/destroy-snapshot-mismatch.log"
if (cd "$tmp/work" && DESTROYING=1 RDS_SNAPSHOT_MISMATCH=1 \
      LIFECYCLE_LOG="$mismatch_log" "$sol" cloud destroy prod/aws/us-east-1 --apply) \
      >"$mismatch_log.out" 2>&1; then
  echo "a destroy whose prepared snapshot identity does not match the provider's must fail" >&2
  cat "$mismatch_log.out" >&2
  exit 1
fi
assert_contains "the snapshot mismatch was reported" "$mismatch_log.out" \
  'final snapshot identifier is' || exit 1
# HARDEN-004 step 4: this failure stands for the target's own declared retention
# guarantee, so it carries Block_destroy -- the target is left standing, the guarantee
# is named as the blocker, and the substrate destroy (the step that removes billable
# infrastructure) is never invoked. "The destroy failed" and "the target remains
# because its retention could not be established" are not the same claim.
assert_contains "the retention guarantee is named as the blocker" "$mismatch_log.out" \
  'destruction is blocked' || exit 1
assert_contains "the guarantee is identified" "$mismatch_log.out" \
  'destroy_retention is final-snapshot' || exit 1
if grep -E -- '-chdir=[^ ]*cloud/aws/cluster ' "$mismatch_log" | grep -F ' destroy ' >/dev/null; then
  echo "the substrate destroy ran although the retention guarantee could not be prepared:" >&2
  cat "$mismatch_log" >&2
  exit 1
fi

# The disposable case, named by the target. The field is inserted directly under
# the AWS target's key, at that body's indentation (FEAT-100: the target lives in
# sol/environments.yml as prod.targets.aws/us-east-1).
envs_file="$tmp/work/sol/environments.yml"
awk '{ print } /^    aws\/us-east-1:[[:space:]]*$/ { print "      destroy_retention: none" }' \
  "$envs_file" >"$tmp/work/envs.with-retention.yml"
mv "$tmp/work/envs.with-retention.yml" "$envs_file"
if ! grep -qE '^      destroy_retention:[[:space:]]*none[[:space:]]*$' "$envs_file"; then
  echo "the retention scenario did not get destroy_retention into the AWS target:" >&2
  cat "$envs_file" >&2
  exit 1
fi

log_none="$tmp/destroy-retention-none.log"
if ! run_destroy "$log_none"; then
  cat "$log_none.out" >&2
  echo "a destroy with destroy_retention: none must succeed" >&2
  exit 1
fi
none_line="$(grep -F -- '-target=aws_db_instance.postgres' "$log_none" | head -1)"
if [ -z "$none_line" ]; then
  echo "the prepare stage did not run for a destroy_retention: none target" >&2
  exit 1
fi
case "$none_line" in
  *'rds_skip_final_snapshot=true'*) : ;;
  *)
    echo "destroy_retention: none did not skip the final snapshot; prepare saw: $none_line" >&2
    exit 1
    ;;
esac
case "$none_line" in
  *'rds_final_snapshot_identifier='*)
    echo "destroy_retention: none still named a snapshot to keep: $none_line" >&2
    exit 1
    ;;
esac
# The verification must agree about what "prepared" means for this mode, and say so.
assert_contains "preparation established that the snapshot will be skipped" "$log_none.out" \
  'final snapshot skipped (skip_final_snapshot=true)' || exit 1
assert_contains "the disposable destroy reports retaining nothing" "$log_none.out" \
  'retention: none' || exit 1
# FND-0046 again: the old report said "no residual billable artifacts" because the
# policy said `none`. The claim now has to name what was actually checked, which is
# the captured database's own manual and automated snapshots.
assert_contains "the disposable destroy names what it checked for residue" "$log_none.out" \
  "no manual or automated snapshot for this target's database" || exit 1
if grep -F 'no residual billable artifacts' "$log_none.out" >/dev/null; then
  echo "the disposable destroy claimed no residual billable artifacts without observing any:" >&2
  cat "$log_none.out" >&2
  exit 1
fi

residue_log="$tmp/destroy-retention-residue.log"
rm -f "$RDS_PREPARED_FILE"
if (export RDS_SNAPSHOT_RESIDUE=1; run_destroy "$residue_log"); then
  echo "a retain-nothing destroy that left a snapshot must fail" >&2
  cat "$residue_log.out" >&2
  exit 1
fi
assert_contains "the residual snapshot was reported by name" "$residue_log.out" \
  'leaked-manual' || exit 1
assert_contains "the residue failure names how many remain" "$residue_log.out" \
  'retain-nothing NOT observed' || exit 1

# DEC-045 / REFAC-094: the AWS destroy does not re-query what Terraform manages (the
# EKS cluster, the RDS instance); the EBS residue query in the same log is the
# positive control that the log records the destroy's provider queries at all.
managed_log="$tmp/destroy-no-managed-queries.log"
rm -f "$RDS_PREPARED_FILE"
if ! run_destroy "$managed_log"; then
  cat "$managed_log.out" >&2
  echo "REFAC-094: the baseline AWS destroy failed" >&2
  exit 1
fi
grep -F 'aws ec2 describe-volumes' "$managed_log" >/dev/null || {
  echo "REFAC-094: the AWS residue (EBS) query is missing from the destroy log" >&2
  exit 1
}
for managed in 'aws eks describe-cluster' 'aws eks describe-addon' 'aws rds describe-db-instances'; do
  if grep -F "$managed" "$managed_log" >/dev/null; then
    echo "REFAC-094: the AWS destroy still re-queries a Terraform-managed resource: $managed" >&2
    exit 1
  fi
done

# The independent state postcondition: a destroy that leaves something represented in
# this root's state is a residue, whatever the provider answers.
residue_state_log="$tmp/destroy-state-residue.log"
rm -f "$RDS_PREPARED_FILE"
if (export STATE_RESIDUE_AFTER_DESTROY=1; run_destroy "$residue_state_log"); then
  echo "a destroy that left the state representing a resource must fail" >&2
  cat "$residue_state_log.out" >&2
  exit 1
fi
assert_contains "the state residue was reported, by address" "$residue_state_log.out" \
  'STILL REPRESENTS module.eks.aws_eks_cluster.this[0], aws_db_instance.postgres' || exit 1

# DEC-040 acceptance on the destroy path, and the decision it makes: the destroy revokes
# the bootstrap access too, so it must observe the window and check the effective surface,
# but that check is advisory. A probe that can fail must not block teardown (ADR 0003
# invariant 6) or strand billable infrastructure (HARDEN-004's cost rule), and a destroy's
# terminal state is the substrate's absence, which is stronger evidence anyway. So an
# indeterminate post-removal probe must be *reported* and the teardown must still complete.
destroy_tri_log="$tmp/destroy-can-i-indeterminate.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window"
if ! (cd "$tmp/work" && DESTROYING=1 CAN_I_FAIL=1 LIFECYCLE_LOG="$destroy_tri_log" \
      "$sol" cloud destroy prod/aws/us-east-1 --apply) >"$destroy_tri_log.out" 2>&1; then
  echo "the destroy was blocked by the de-escalation probe, which must never strand a target:" >&2
  cat "$destroy_tri_log.out" >&2
  exit 1
fi
grep -qF 'effective removal could not be verified' "$destroy_tri_log.out" || {
  echo "the destroy completed but never reported that the removal could not be verified:" >&2
  cat "$destroy_tri_log.out" >&2
  exit 1
}
grep -qF 'no usable answer' "$destroy_tri_log.out" || {
  echo "the destroy warning did not name the indeterminate probe:" >&2
  cat "$destroy_tri_log.out" >&2
  exit 1
}

# An absent target (cloud substrate never applied) has nothing to prepare and
# must not attempt the targeted apply.
rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-absent.log"
if ! (export OUTPUT_ABSENT=1; run_destroy "$log"); then
  cat "$log.out" >&2
  echo "cloud destroy on an absent target must still succeed" >&2
  exit 1
fi
grep -F 'prepare: cloud substrate is absent, nothing to prepare' "$log.out" >/dev/null
if grep -F -- '-target=aws_db_instance.postgres' "$log" >/dev/null; then
  echo "cloud destroy attempted RDS preparation on an absent cloud substrate" >&2
  exit 1
fi

# Cloud substrate exists but this target never created an RDS instance:
# distinct from the wholly-absent case above (cloud_destroy still has real
# outputs and reaches prepare_destroy), and must also skip the targeted apply.
rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-no-rds.log"
if ! (export RDS_ABSENT=1; run_destroy "$log"); then
  cat "$log.out" >&2
  echo "cloud destroy on a target with no RDS instance must still succeed" >&2
  exit 1
fi
grep -F 'prepare: no RDS instance for this target, nothing to prepare' "$log.out" >/dev/null
if grep -F -- '-target=aws_db_instance.postgres' "$log" >/dev/null; then
  echo "cloud destroy attempted RDS preparation when no RDS instance exists" >&2
  exit 1
fi

# ADR 0003 invariant 6 (HARDEN-002 run 5): destruction is an abort edge, not a
# forward transition. A failed or partially installed target must remain
# destructible through the public lifecycle, because lifecycle enforcement must
# never strand infrastructure.
#
# This is the case the model and the operation used to disagree about: the
# forward relation rejects `PlatformInstalling -> PreparingDestroy` (correctly --
# it describes progressive establishment), so routing destroy through `enter`
# would refuse to tear down a half-built target and leave the operator with no
# exit but manual surgery on live cloud resources.
#
# The marker is removed so the target reads as "substrate exists, platform never
# fully installed"; a future implementation that consults the phase here, or that
# gates teardown on a probe which can fail, fails this scenario. Nothing follows
# this scenario, so the harness state is not restored.
rm -f "$RDS_PREPARED_FILE"
rm -f "$PLATFORM_INSTALLED_FILE"
log="$tmp/destroy-partial-install.log"
if ! run_destroy "$log"; then
  cat "$log.out" >&2
  echo "cloud destroy on a partially installed target must succeed (invariant 6)" >&2
  exit 1
fi
grep -F 'lifecycle phase: PreparingDestroy' "$log.out" >/dev/null || {
  echo "destroy on a partially installed target did not enter the destruction phase:" >&2
  cat "$log.out" >&2
  exit 1
}
# INFRA-031: the substrate teardown itself is Destroying, reported where the
# lifecycle actually enters it (preparation verified, platform already gone).
grep -F 'lifecycle phase: Destroying' "$log.out" >/dev/null || {
  echo "destroy did not report Destroying while tearing the cloud substrate down:" >&2
  cat "$log.out" >&2
  exit 1
}

# DEC-040 canary. The bootstrap-access-removal phase is where the de-escalation transition
# is verified, and it is the point of the install path. If this harness never enters it,
# the transition coverage is absent while every assertion here still passes -- so assert
# that the harness actually reached it, and fail loudly rather than passing vacuously.
if ! grep -lF 'provisioner-bootstrap-access-remove' "$tmp"/*.out >/dev/null 2>&1 &&
   ! grep -lF 'provisioner-bootstrap-access-remove' ./*.out >/dev/null 2>&1; then
  echo "DEC-040 canary: this harness never entered the bootstrap-access-removal phase," >&2
  echo "so it exercised no de-escalation transition at all -- the unit cases would be" >&2
  echo "carrying the whole load without anything here noticing." >&2
  exit 1
fi

# DEC-040 shape gate. The fixtures encode a shape recalled from the API; the gate is what
# compares that against an answer. Assert it ran and did not reject the shape, so the
# coverage cannot quietly go absent -- and so a shape the parser cannot read fails here
# rather than at the end of a live bootstrap.
if ! grep -lF 'whoami shape: parsed' "$tmp"/*.out >/dev/null 2>&1; then
  echo "DEC-040 canary: the whoami shape gate never reported a parsed response, so either it" >&2
  echo "did not run or it rejected the emulated shape -- the fixtures would be going" >&2
  echo "unvalidated against anything." >&2
  exit 1
fi

# INFRA-076: the previous Terraform operation against a state decides whether an apply
# may proceed. Every lock-taking terraform call above ran under Sol's supervisor, which
# left an operation record per state under $XDG_DATA_HOME/sol/operations.
ops="$XDG_DATA_HOME/sol/operations"
pre_log="$tmp/infra076-pre.log"
if ! (export FAIL_ON=""; run_apply "$pre_log"); then
  cat "$pre_log.out" >&2
  echo "INFRA-076: the baseline apply failed" >&2
  exit 1
fi
aws_key="$(ls -t "$ops" 2>/dev/null | grep '^aws-' | head -1 || true)"
if [ -z "$aws_key" ] || [ ! -s "$ops/$aws_key/latest" ]; then
  echo "INFRA-076: no operation record for the AWS cloud root under $ops" >&2
  ls -la "$ops" >&2 || true
  exit 1
fi
latest="$ops/$aws_key/$(cat "$ops/$aws_key/latest")"
assert_contains "INFRA-076: the supervisor recorded terraform's outcome" "$latest/exit" 'exited 0' || exit 1

# Unresolved: Terraform was killed before finishing its own protocol. An apply must not
# proceed as though nothing happened.
printf 'signaled 9\n' >"$latest/exit"
unresolved_log="$tmp/infra076-unresolved.log"
if (export FAIL_ON=""; run_apply "$unresolved_log"); then
  cat "$unresolved_log.out" >&2
  echo "INFRA-076: an apply proceeded past an unresolved previous operation" >&2
  exit 1
fi
assert_contains "INFRA-076: the unresolved operation is named" "$unresolved_log.out" \
  'refusing to apply: the previous Terraform operation against this state is unresolved' || exit 1
assert_not_contains "INFRA-076: no terraform apply ran" "$unresolved_log.out" '[terraform-apply]' || exit 1

# ...and proceeds once the operator says it is reconciled, recording that.
accept_log="$tmp/infra076-accept.log"
if ! (cd "$tmp/work" && FAIL_ON="" LIFECYCLE_LOG="$accept_log" \
        "$sol" cloud apply prod/aws/us-east-1 --accept-unresolved) >"$accept_log.out" 2>&1; then
  cat "$accept_log.out" >&2
  echo "INFRA-076: --accept-unresolved did not let the apply proceed" >&2
  exit 1
fi
[ -e "$latest/acknowledged" ] || {
  echo "INFRA-076: accepting an unresolved operation was not recorded" >&2
  exit 1
}

# Running: a live supervisor holds this state. Never race it, never unlock it.
sleep 60 &
live_pid=$!
running="$ops/$aws_key/99999999T000000Z-running"
mkdir -p "$running"
printf 'host=%s\nsupervisor_pid=%s\nsupervisor_start=\nstarted_at=%s\nroot=%s\n' \
  "$(hostname)" "$live_pid" "$(date +%s)" "$(sed -n 's/^root=//p' "$latest/meta")" >"$running/meta"
printf '%s\n' "$(basename "$running")" >"$ops/$aws_key/latest"
running_log="$tmp/infra076-running.log"
if (export FAIL_ON=""; run_apply "$running_log"); then
  kill "$live_pid" 2>/dev/null || true
  cat "$running_log.out" >&2
  echo "INFRA-076: an apply raced a running previous operation" >&2
  exit 1
fi
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
assert_contains "INFRA-076: the running operation is reported" "$running_log.out" \
  'is still running and holds its lock' || exit 1

# AUDIT-POST-004: destroy works in the platform root too (init, the destroy preview,
# the platform teardown), so the platform root's own previous operation decides
# whether it may proceed -- exactly as the cloud root's does on apply. The cloud
# root's record is left Resolved first, so a refusal below can only have come from
# the platform root, not from a leftover cloud-root record.
printf 'exited 0\n' >"$latest/exit"
# Which key is the AWS platform root's? Its own record says so: `root=` in the
# operation meta is the Terraform working directory, and the GCP platform root's
# records carry a different one. Selecting by that (most recent first) is
# unambiguous, where a name prefix alone need not be.
platform_key=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  dir="$ops/$candidate/$(cat "$ops/$candidate/latest" 2>/dev/null || true)"
  # DEC-050: that working directory is the state's own, under Sol's state directory.
  if [ -f "$dir/meta" ] &&
     grep -qxE "root=$XDG_DATA_HOME/sol/terraform/aws-platform-[0-9a-f]{16}/platform/cloud/aws/platform" "$dir/meta"; then
    platform_key="$candidate"
    break
  fi
done < <(ls -t "$ops" 2>/dev/null)
if [ -z "$platform_key" ] || [ ! -s "$ops/$platform_key/latest" ]; then
  echo "AUDIT-POST-004: no operation record for the AWS platform root under $ops" >&2
  ls -la "$ops" >&2 || true
  exit 1
fi

# Running: never start conflicting platform work.
sleep 60 &
platform_live_pid=$!
platform_running="$ops/$platform_key/99999999T000000Z-platform-running"
mkdir -p "$platform_running"
printf 'host=%s\nsupervisor_pid=%s\nsupervisor_start=\nstarted_at=%s\nroot=%s\n' \
  "$(hostname)" "$platform_live_pid" "$(date +%s)" \
  "$(sed -n 's/^root=//p' "$ops/$platform_key/$(cat "$ops/$platform_key/latest")/meta")" \
  >"$platform_running/meta"
printf '%s\n' "$(basename "$platform_running")" >"$ops/$platform_key/latest"
platform_running_log="$tmp/infra076-platform-running.log"
rm -f "$RDS_PREPARED_FILE"
if (export FAIL_ON=""; run_destroy "$platform_running_log"); then
  kill "$platform_live_pid" 2>/dev/null || true
  cat "$platform_running_log.out" >&2
  echo "AUDIT-POST-004: a destroy raced a running platform operation" >&2
  exit 1
fi
kill "$platform_live_pid" 2>/dev/null || true
wait "$platform_live_pid" 2>/dev/null || true
assert_contains "AUDIT-POST-004: the running platform operation is reported" \
  "$platform_running_log.out" 'is still running and holds its lock' || exit 1
if [ -e "$platform_running_log" ] && grep -q 'terraform' "$platform_running_log"; then
  echo "AUDIT-POST-004: the refusal of a running platform operation still ran terraform" >&2
  cat "$platform_running_log" >&2
  exit 1
fi

# Unresolved: named, and destruction proceeds. A destroy constructs nothing from the
# gap, so the established policy for a non-constructive command is to report it
# rather than refuse it -- the answer the cloud root gets today.
printf 'signaled 9\n' >"$platform_running/exit"
printf '%s\n' "$(basename "$platform_running")" >"$ops/$platform_key/latest"
platform_unresolved_log="$tmp/infra076-platform-unresolved.log"
rm -f "$RDS_PREPARED_FILE"
if ! (export FAIL_ON=""; run_destroy "$platform_unresolved_log"); then
  cat "$platform_unresolved_log.out" >&2
  echo "AUDIT-POST-004: an unresolved platform operation stopped a destroy" >&2
  exit 1
fi
assert_contains "AUDIT-POST-004: the unresolved platform operation is reported" \
  "$platform_unresolved_log.out" \
  'the previous Terraform operation against this state is unresolved' || exit 1

# Resolved: destruction proceeds with no such report.
printf 'exited 0\n' >"$platform_running/exit"
printf '%s\n' "$(basename "$platform_running")" >"$ops/$platform_key/latest"
platform_resolved_log="$tmp/infra076-platform-resolved.log"
rm -f "$RDS_PREPARED_FILE"
if ! (export FAIL_ON=""; run_destroy "$platform_resolved_log"); then
  cat "$platform_resolved_log.out" >&2
  echo "AUDIT-POST-004: a resolved platform operation stopped a destroy" >&2
  exit 1
fi
if grep -qF 'the previous Terraform operation against this state is unresolved' \
     "$platform_resolved_log.out"; then
  echo "AUDIT-POST-004: a resolved platform operation was reported as unresolved" >&2
  exit 1
fi

# BUG-057: a target's relative terraform_var_file resolves from the workspace root, so
# the same target names the same file from any directory; a relative --var-file flag
# resolves from the shell's directory. Both run from a subdirectory of the workspace,
# which is where the old cwd-relative rule went wrong.
target_file="$tmp/work/sol/environments.yml"
cp "$target_file" "$tmp/work/target.before-bug057.yml"
mkdir -p "$tmp/work/vars" "$tmp/work/app/deep"
: >"$tmp/work/vars/bug057.tfvars"
: >"$tmp/work/app/deep/flag.tfvars"
awk '{ print } /^    aws\/us-east-1:[[:space:]]*$/ { print "      terraform_var_file: vars/bug057.tfvars" }' \
  "$tmp/work/target.before-bug057.yml" >"$target_file"
vlog="$tmp/bug057-target.log"
(cd "$tmp/work/app/deep" && LIFECYCLE_LOG="$vlog" "$sol" cloud plan prod/aws/us-east-1) \
  >"$vlog.out" 2>&1 || true
if ! grep -F -- "-var-file=$tmp/work/vars/bug057.tfvars" "$vlog" >/dev/null; then
  echo "BUG-057: a target's relative terraform_var_file did not resolve from the workspace root:" >&2
  grep -o -- '-var-file=[^ ]*' "$vlog" "$vlog.out" >&2 || cat "$vlog.out" >&2
  exit 1
fi
flog="$tmp/bug057-flag.log"
(cd "$tmp/work/app/deep" && LIFECYCLE_LOG="$flog" "$sol" cloud plan prod/aws/us-east-1 --var-file flag.tfvars) \
  >"$flog.out" 2>&1 || true
if ! grep -F -- "-var-file=$tmp/work/app/deep/flag.tfvars" "$flog" >/dev/null; then
  echo "BUG-057: a relative --var-file did not resolve from the shell's directory:" >&2
  grep -o -- '-var-file=[^ ]*' "$flog" "$flog.out" >&2 || cat "$flog.out" >&2
  exit 1
fi
if grep -F -- "bug057.tfvars" "$flog" >/dev/null; then
  echo "BUG-057: --var-file did not win over the target's terraform_var_file" >&2
  exit 1
fi
mv "$tmp/work/target.before-bug057.yml" "$target_file"

# ── DEC-050: Terraform runs in a per-state working directory ───────────────────
# The roots in Sol's assets are immutable; every Terraform invocation above ran in a
# working directory under Sol's state, materialized from them.
workdirs="$XDG_DATA_HOME/sol/terraform"
for role in aws-cluster aws-platform gcp-cluster gcp-platform; do
  if ! ls -d "$workdirs/$role"-* >/dev/null 2>&1; then
    echo "DEC-050: no working directory for $role under $workdirs" >&2
    ls -la "$workdirs" >&2 || true
    exit 1
  fi
done
chdirs="$(cat "$tmp"/*.log 2>/dev/null | grep -oE -- '-chdir=[^ ]+' | sort -u | sed 's/^-chdir=//')"
[ -n "$chdirs" ] || { echo "DEC-050: no terraform -chdir recorded" >&2; exit 1; }
while IFS= read -r d; do
  case "$d" in
    "$workdirs"/*/platform/cloud/*/*) ;;
    *) echo "DEC-050: terraform ran outside a working directory: $d" >&2; exit 1 ;;
  esac
done <<<"$chdirs"
echo "DEC-050: every terraform -chdir was a working directory ($(wc -l <<<"$chdirs") distinct)"

# Nothing was written into the assets: no Terraform directory, no state, no errored state.
if find "$root/platform" -newer "$tmp/bin/terraform" \( -name .terraform -o -name '*.tfstate' -o -name errored.tfstate \) | grep -q .; then
  echo "DEC-050: a Terraform run wrote into Sol's assets:" >&2
  find "$root/platform" -newer "$tmp/bin/terraform" \( -name .terraform -o -name '*.tfstate' \) >&2
  exit 1
fi

aws_wd="$(sed -n 's/^root=//p' "$ops/$aws_key/$(cat "$ops/$aws_key/latest")/meta")"
case "$aws_wd" in "$workdirs"/aws-cluster-*/platform/cloud/aws/cluster) ;; *)
  echo "DEC-050: the AWS cloud root's operation record names $aws_wd" >&2; exit 1 ;;
esac
wd_base="${aws_wd%/platform/cloud/aws/cluster}"
[ -e "$aws_wd/.terraform/fake-init" ] || { echo "DEC-050: init did not run in $aws_wd" >&2; exit 1; }

# Each provider's cluster root has its own working directory (per-target isolation is
# the unit test's: cli/test/test_terraform_workdir.ml, `identity isolates states`).
if [ "$(ls -d "$workdirs"/*-cluster-* | wc -l)" -lt 2 ]; then
  echo "DEC-050: expected a cluster working directory per provider" >&2; ls "$workdirs" >&2; exit 1
fi

run_plan_aws() {
  (cd "$tmp/work" && FAIL_ON="" LIFECYCLE_LOG="$1" "$sol" cloud plan prod/aws/us-east-1) >"$1.out" 2>&1
}

# Every invocation starts from the authoritative assets: a tampered source file is
# restored, a source file Sol wrote that the assets no longer have is removed, and
# anything Sol did not write stays.
printf 'tampered\n' >"$aws_wd/main.tf"
: >"$aws_wd/stale-from-an-older-release.tf"
printf 'platform/cloud/aws/cluster/stale-from-an-older-release.tf\n' >>"$wd_base/.sol-materialized"
printf 'operator notes\n' >"$aws_wd/operator-notes.txt"
refresh_log="$tmp/dec050-refresh.log"
run_plan_aws "$refresh_log" || { cat "$refresh_log.out" >&2; echo "DEC-050: plan failed" >&2; exit 1; }
cmp -s "$aws_wd/main.tf" "$root/platform/cloud/aws/cluster/main.tf" ||
  { echo "DEC-050: a tampered source file survived re-materialization" >&2; exit 1; }
[ ! -e "$aws_wd/stale-from-an-older-release.tf" ] ||
  { echo "DEC-050: a source file the assets no longer have was left in place" >&2; exit 1; }
[ -e "$aws_wd/operator-notes.txt" ] ||
  { echo "DEC-050: a file Sol did not write was removed" >&2; exit 1; }
[ -e "$aws_wd/.terraform/fake-init" ] ||
  { echo "DEC-050: Terraform's own directory was removed" >&2; exit 1; }
echo "DEC-050: re-materialization restores sources, drops stale ones, keeps what Sol did not write"

# errored.tfstate: the only record of a run whose state push failed. It must be
# reported, refuse a constructive command, and survive every later invocation --
# including the ones that re-materialize the working directory around it.
printf '{"version":4,"serial":7,"lineage":"dec050"}\n' >"$aws_wd/errored.tfstate"
cp "$aws_wd/errored.tfstate" "$tmp/errored.expected"
errored_log="$tmp/dec050-errored.log"
if (export FAIL_ON=""; run_apply "$errored_log"); then
  cat "$errored_log.out" >&2
  echo "DEC-050: an apply proceeded past an errored.tfstate in its working directory" >&2
  exit 1
fi
assert_contains "DEC-050: the errored state is named at its working-directory path" \
  "$errored_log.out" "$aws_wd/errored.tfstate" || exit 1
cmp -s "$aws_wd/errored.tfstate" "$tmp/errored.expected" ||
  { echo "DEC-050: a refused apply touched errored.tfstate" >&2; exit 1; }
errored_plan_log="$tmp/dec050-errored-plan.log"
run_plan_aws "$errored_plan_log" || { cat "$errored_plan_log.out" >&2; echo "DEC-050: plan failed" >&2; exit 1; }
errored_accept_log="$tmp/dec050-errored-accept.log"
(cd "$tmp/work" && FAIL_ON="" LIFECYCLE_LOG="$errored_accept_log" \
   "$sol" cloud apply prod/aws/us-east-1 --accept-unresolved) >"$errored_accept_log.out" 2>&1 || {
  cat "$errored_accept_log.out" >&2; echo "DEC-050: --accept-unresolved apply failed" >&2; exit 1; }
cmp -s "$aws_wd/errored.tfstate" "$tmp/errored.expected" ||
  { echo "DEC-050: errored.tfstate did not survive a plan and an accepted apply" >&2; exit 1; }
rm -f "$aws_wd/errored.tfstate"
echo "DEC-050: errored.tfstate is reported, refuses apply, and survives re-materialization"

# Read-only assets: Sol never needs to write them.
ro_home="$tmp/ro-sol-home"
mkdir -p "$ro_home/framework/ocaml/sol-svc/lib" "$ro_home/framework/ocaml/kafka-eio-service/lib"
: >"$ro_home/framework/ocaml/sol-svc/lib/dune"
: >"$ro_home/framework/ocaml/kafka-eio-service/lib/dune"
cp -r "$root/platform" "$ro_home/platform"
find "$ro_home/platform" \( -name .terraform -o -name '*.tfstate' \) -prune -exec rm -rf {} +
chmod -R a-w "$ro_home"
ro_log="$tmp/dec050-readonly.log"
if ! (cd "$tmp/work" && FAIL_ON="" SOL_HOME="$ro_home" LIFECYCLE_LOG="$ro_log" \
        "$sol" cloud plan prod/aws/us-east-1) >"$ro_log.out" 2>&1; then
  chmod -R u+w "$ro_home"
  cat "$ro_log.out" >&2
  echo "DEC-050: sol cloud plan failed against read-only assets" >&2
  exit 1
fi
chmod -R u+w "$ro_home"
grep -q -- "-chdir=$workdirs/" "$ro_log" || { echo "DEC-050: read-only run did not use a working directory" >&2; exit 1; }
echo "DEC-050: sol cloud plan runs against read-only assets"

# REFAC-115: SOL_DESTROY_SNAPSHOT_INTERVAL_S is read when a destroy needs it. A
# malformed value used to be evaluated at program start, so every command exited 2.
# Now an unrelated command is unaffected, and a destroy that retains a final
# snapshot (the default) refuses in preparation -- before anything is destroyed.
if ! SOL_DESTROY_SNAPSHOT_INTERVAL_S=abc "$sol" --version >/dev/null 2>&1; then
  echo "REFAC-115: a malformed SOL_DESTROY_SNAPSHOT_INTERVAL_S broke an unrelated command" >&2
  exit 1
fi
interval_log="$tmp/refac115-interval.log"
# The AWS target retains its final snapshot (the default) for this scenario: drop
# the destroy_retention: none an earlier scenario inserted under it, and restore it.
cp "$tmp/work/sol/environments.yml" "$tmp/work/envs.before-refac115.yml"
awk '/^    aws\/us-east-1:[[:space:]]*$/ { in_aws = 1; print; next }
     /^    [^ ]/ { in_aws = 0 }
     !(in_aws && /^      destroy_retention:[[:space:]]*none[[:space:]]*$/) { print }' \
  "$tmp/work/envs.before-refac115.yml" >"$tmp/work/sol/environments.yml"
if grep -A3 '^    aws/us-east-1:' "$tmp/work/sol/environments.yml" | grep -q 'destroy_retention: none'; then
  echo "REFAC-115: could not put the AWS target back on final-snapshot retention" >&2; exit 1
fi
if (cd "$tmp/work" && FAIL_ON="" DESTROYING=1 SOL_DESTROY_SNAPSHOT_INTERVAL_S=abc \
      LIFECYCLE_LOG="$interval_log" "$sol" cloud destroy prod/aws/us-east-1 --apply) \
    >"$interval_log.out" 2>&1; then
  cat "$interval_log.out" >&2
  echo "REFAC-115: a destroy proceeded with a malformed snapshot interval" >&2
  exit 1
fi
assert_contains "REFAC-115: the refusal names the setting" "$interval_log.out" \
  'SOL_DESTROY_SNAPSHOT_INTERVAL_S="abc" is not a non-negative number of seconds' || exit 1
if grep -E '^terraform .* destroy( |$)' "$interval_log" >/dev/null 2>&1; then
  echo "REFAC-115: terraform destroy ran despite the refused preparation:" >&2
  grep -E '^terraform .* destroy' "$interval_log" >&2
  exit 1
fi
mv "$tmp/work/envs.before-refac115.yml" "$tmp/work/sol/environments.yml"
echo "REFAC-115: a malformed snapshot interval refuses the destroy, and only the destroy"

# INFRA-075 canary. The scenarios above ran the real `sol cloud` commands; their run logs must
# have landed in the isolated data home. If none did, Sol is writing somewhere else -- most
# likely the operator's real ~/.local/share/sol, where the keep-20 pruning deletes real runs.
# (Any `cloud-*` run proves it: Sol keeps only the latest 20, so the earlier apply runs are
# pruned by the later destroys inside the isolated home too.)
if ! ls -d "$XDG_DATA_HOME"/sol/runs/cloud-* >/dev/null 2>&1; then
  echo "INFRA-075 canary: no cloud-* run logs under the isolated" >&2
  echo "XDG_DATA_HOME ($XDG_DATA_HOME), so this harness wrote its runs somewhere else --" >&2
  echo "probably the operator's real Sol home, where they prune real evidence." >&2
  exit 1
fi
