# platform/cloud/modules/platform — the shared, cluster-agnostic platform definition
#
# Installs all Sol platform components onto an existing Kubernetes cluster using
# Helm. This is a module, not a root: it declares no backend, and each provider
# applies it through its own platform root (platform/cloud/aws/platform,
# platform/cloud/gcp/platform) after that provider's cluster root. `sol cloud apply`
# runs both; the cluster kubeconfig must be active before the platform root applies.
#
# Components installed:
#   cert-manager       — TLS certificate automation (Let's Encrypt)
#   ingress-nginx      — Ingress controller
#   Argo CD            — GitOps continuous delivery
#   Redpanda           — Kafka-compatible broker + schema registry
#   PostgreSQL         — Primary database (use platform/cloud/aws/cluster RDS for production)
#   Loki + Grafana     — Log aggregation and dashboards
#   Alloy              — Cluster-wide pod log shipping (Promtail's successor)
#   Prometheus         — Metrics collection and Pushgateway
#   Tempo              — Distributed tracing (OBS-042; -svc only, see obs-tempo-eio)

terraform {
  required_version = ">= 1.6"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

# ── Namespaces ────────────────────────────────────────────────────────────── #

resource "kubernetes_namespace" "cert_manager" {
  metadata { name = "cert-manager" }
}

resource "kubernetes_namespace" "ingress_nginx" {
  metadata { name = "ingress-nginx" }
}

resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

resource "kubernetes_namespace" "redpanda" {
  metadata { name = "redpanda" }
}

resource "kubernetes_namespace" "postgresql" {
  metadata { name = "postgresql" }
  count = var.install_postgresql ? 1 : 0
}

resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "terraform_data" "observability_backend_validation" {
  input = var.observability_backend

  lifecycle {
    precondition {
      condition = var.observability_backend != "external" || (
        trimspace(var.external_loki_url) != "" &&
        trimspace(var.external_prometheus_remote_write_url) != ""
      )
      error_message = "observability_backend = \"external\" requires external_loki_url and external_prometheus_remote_write_url."
    }

    precondition {
      condition = var.observability_backend != "external" || (
        (trimspace(var.external_loki_username) == "" && trimspace(var.external_loki_password) == "") ||
        (trimspace(var.external_loki_username) != "" && trimspace(var.external_loki_password) != "")
      )
      error_message = "external_loki_username and external_loki_password must be set together."
    }

    precondition {
      condition = var.observability_backend != "external" || (
        (trimspace(var.external_prometheus_username) == "" && trimspace(var.external_prometheus_password) == "") ||
        (trimspace(var.external_prometheus_username) != "" && trimspace(var.external_prometheus_password) != "")
      )
      error_message = "external_prometheus_username and external_prometheus_password must be set together."
    }

    precondition {
      condition = var.observability_backend != "self_hosted_durable" || var.cloud_provider != "aws" || (
        trimspace(var.loki_s3_bucket) != "" &&
        trimspace(var.loki_irsa_role_arn) != "" &&
        trimspace(var.thanos_s3_bucket) != "" &&
        trimspace(var.thanos_irsa_role_arn) != ""
      )
      error_message = "observability_backend = \"self_hosted_durable\" on AWS requires loki_s3_bucket, loki_irsa_role_arn, thanos_s3_bucket, and thanos_irsa_role_arn."
    }

    # INFRA-005: GCP counterpart to the AWS precondition above -- kept even
    # though the gate below still blocks cloud_provider == "gcp" entirely, so
    # the requirement is already correct and doesn't need revisiting the day
    # that gate is relaxed.
    precondition {
      condition = var.observability_backend != "self_hosted_durable" || var.cloud_provider != "gcp" || (
        trimspace(var.loki_gcs_bucket) != "" &&
        trimspace(var.loki_workload_identity_sa_email) != "" &&
        trimspace(var.thanos_gcs_bucket) != "" &&
        trimspace(var.thanos_workload_identity_sa_email) != ""
      )
      error_message = "observability_backend = \"self_hosted_durable\" on GCP requires loki_gcs_bucket, loki_workload_identity_sa_email, thanos_gcs_bucket, and thanos_workload_identity_sa_email."
    }

    # INFRA-005: this is the one remaining, deliberate gate. Everything else
    # in this module now accepts and wires GCP's durable-observability
    # inputs the same way it does AWS's, but the Helm-values GCS path has
    # only been validated statically (terraform validate/fmt), never against
    # a live GKE cluster -- see INFRA-005's ticket for why. Relax this once
    # that live validation has actually happened, not before.
    precondition {
      condition     = var.observability_backend != "self_hosted_durable" || var.cloud_provider == "aws"
      error_message = "observability_backend = \"self_hosted_durable\" is currently supported only on AWS/EKS: the GCP Workload Identity path is wired but not yet validated against a live GKE cluster (INFRA-005)."
    }
  }
}

# OBS-044: managed-resource dashboards (RDS today) are CloudWatch-backed and
# need Grafana's own pod to carry an IRSA role -- same "AWS/EKS only because
# it uses IRSA" constraint as self_hosted_durable above, plus the IRSA role
# ARN itself.
resource "terraform_data" "managed_resource_dashboards_validation" {
  input = var.managed_resource_dashboards

  lifecycle {
    precondition {
      condition     = length(var.managed_resource_dashboards) == 0 || var.cloud_provider == "aws"
      error_message = "managed_resource_dashboards is currently supported only on AWS/EKS (CloudWatch-backed, requires IRSA)."
    }

    precondition {
      condition     = length(var.managed_resource_dashboards) == 0 || trimspace(var.grafana_irsa_role_arn) != ""
      error_message = "managed_resource_dashboards requires grafana_irsa_role_arn (from platform/cloud/aws/cluster's grafana_irsa_arn output) so Grafana's CloudWatch datasource can authenticate."
    }
  }
}

# ── cert-manager ──────────────────────────────────────────────────────────── #

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.14.4"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set {
    name  = "installCRDs"
    value = "true"
  }

  # ── FND-0060: leader election belongs in cert-manager's own namespace ──────
  #
  # The chart's default is `global.leaderElection.namespace: kube-system`; it creates its
  # leader-election Role and RoleBinding there and passes the same namespace to both the
  # controller and the cainjector as `--leader-election-namespace`. GKE Autopilot manages
  # `kube-system` and denies workloads the create verb in it, so on Autopilot the components
  # can never create their Lease. Attempt 10's frozen evidence (2026-09-26) shows the whole
  # consequence: 30 denials each across the entire install window
  #
  #   cannot create resource "leases" in API group "coordination.k8s.io" in the namespace
  #   "kube-system": GKE Warden authz [denied by managed-namespaces-limitation]
  #
  # no leadership, so cainjector never injected the webhook's caBundle (the
  # ValidatingWebhookConfiguration had no caBundle field at all), so every client's TLS
  # handshake to the webhook failed and cert-manager's own post-install `check api
  # --wait=10m` polled for its full 601s and timed out -- which is what fails the platform
  # apply, and what FND-0010's budget remedy (below) was never able to fix on its own.
  #
  # Deliberately unconditional. A cluster that would permit `kube-system` is not a reason to
  # depend on it: the namespace Sol installs cert-manager into is the namespace its
  # leader-election resources belong in, so the reference below has one meaning everywhere
  # and no provider-specific branch decides it.
  set {
    name  = "global.leaderElection.namespace"
    value = kubernetes_namespace.cert_manager.metadata[0].name
  }

  # ── FND-0010: wait as long as cert-manager's own readiness check is designed to ──
  #
  # The chart's post-install `startupapicheck` Job is cert-manager's readiness contract:
  # it dry-run creates a Certificate, so the API server has to call the validating
  # webhook, and it polls every 5s until the webhook answers. It cannot pass until
  # cainjector has injected the CA bundle (the webhook pod writes the CA Secret, and
  # cainjector copies it into the webhook configuration) -- on a fresh cluster that is
  # both components racing the cluster's own first-boot work.
  #
  # The provider's default `timeout` is 300s, and it bounds *that hook's wait* too. So
  # Terraform gave up on a check that cert-manager designed to keep trying: every GCP
  # attempt failed the platform apply with
  #   `Error: failed post-install: 1 error occurred: * timed out waiting for the condition`
  # while the startupapicheck log was still polling and reporting
  #   `x509: certificate signed by unknown authority`  (Attempts 4, 5, 8, 9).
  # Attempt 9 pins the arithmetic: the hook Job was created at 01:52:46 and the apply
  # failed at ~01:57:41 -- 300s later, on the dot -- with the webhook configuration
  # still at `generation: 1` and no caBundle.
  #
  # So: keep the check (it is the only signal that the webhook is usable, and every
  # certificate-bearing component after cert-manager depends on it), give it one
  # continuous poll window that outlasts a slow first install, and give Terraform a
  # wait that outlasts the check. Worst case is (backoffLimit + 1) x timeout ~= 21
  # minutes, inside the 30-minute release bound below; a check that still fails then
  # fails the stage, which is correct -- the components after cert-manager cannot work
  # without a usable webhook. Deliberately not `atomic`: a failed release stays in
  # place for the operator to inspect, which is the failure shape FND-0058 qualified.
  set {
    name  = "startupapicheck.timeout"
    value = "10m"
  }

  set {
    name  = "startupapicheck.backoffLimit"
    value = "1"
  }

  # 30 minutes: an explicit outer bound on a first install, strictly greater than the
  # check's worst case above, so Terraform can never cut the check short again. It has
  # to be set explicitly rather than left to the 300s default for the same reason.
  timeout = 1800

  # The chart's resources must be ready before its own post-install check runs, so the
  # wait is load-bearing, not incidental. The provider defaults this to true; stating
  # it keeps a future default change from silently turning the readiness gate off.
  wait = true
}

# ── ingress-nginx ─────────────────────────────────────────────────────────── #

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.10.1"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  set {
    name  = "controller.service.type"
    value = var.ingress_service_type
  }

  depends_on = [helm_release.cert_manager]
}

# ── Argo CD ───────────────────────────────────────────────────────────────── #

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.3"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Disable TLS termination at Argo CD — handled by ingress-nginx
  set {
    name  = "server.insecure"
    value = "true"
  }
}

# Expose Argo CD UI via Ingress
resource "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      "cert-manager.io/cluster-issuer"           = var.cluster_issuer
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = ["argocd.${var.base_domain}"]
      secret_name = "argocd-tls"
    }

    rule {
      host = "argocd.${var.base_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.argocd, helm_release.ingress_nginx]
}

# ── Redpanda (Kafka + schema registry) ───────────────────────────────────── #

resource "helm_release" "redpanda" {
  name       = "redpanda"
  repository = "https://charts.redpanda.com"
  chart      = "redpanda"
  # FRIC-007: 5.8.12 (image v24.1.8) predates JSON Schema Registry support
  # (landed in Redpanda 24.2, redpanda-data/redpanda#6220) -- every real Sol
  # service registers its schema with `schemaType: "JSON"` unconditionally,
  # which this version rejects outright with HTTP 422. 5.9.15 (image v24.2.7)
  # was the smallest bump that provably has the fix. FRIC-010 evaluated a
  # further modernization and declined it (in-place v24.2.7 -> 26.x upgrades
  # trip Redpanda's own logical-version check), which was safe only while
  # 5.9.15 stayed installable. INFRA-013: upstream retired the 5.x line from
  # the charts.redpanda.com index in 2026-09, so the pin moves to 26.1.11
  # (image v26.1.17) -- FRIC-010's evaluated target, one minor behind newest
  # and within support. A cluster still on v24.2.7 must be recreated rather
  # than upgraded in place. NOTE: this bump also flips console.enabled to false
  # (the common layer, a chart values.schema.json workaround) -- on an
  # already-deployed environment, `terraform apply` tears Redpanda Console's
  # Deployment/Service/ConfigMap/ServiceAccount down, not just skips installing
  # them. Verified safe (ClusterIP-only, no ingress, nothing in Sol references
  # it), but a real operator diffing a real plan should expect that deletion.
  # Keep this in sync with cmd_local.ml's pin (CODE_LAYER-008).
  version   = "26.1.11"
  namespace = kubernetes_namespace.redpanda.metadata[0].name
  timeout   = 600

  # CODE_LAYER-010: tls.enabled/config.cluster.auto_create_topics_enabled
  # now live in platform/shared/components.json (redpanda.common) (ADR 0001),
  # shared with cmd_local.ml's own Redpanda install. statefulset.replicas/
  # resources.cpu.cores also appear in the local layer (for cmd_local.ml's
  # benefit only) but are safely overridden here regardless, since this
  # block is the LAST entry in the values list. What's left here
  # (replicas/cpu/memory/persistence) is genuinely Terraform-only --
  # driven by operator variables cmd_local.ml has no equivalent for, same
  # reasoning as Loki's singleBinary.persistence.enabled `set` above.
  #
  # storage.persistentVolume.size and cmd_local.ml's external.*/
  # listeners.kafka.* block are deliberately NOT in
  # platform/shared/components.json (redpanda) at all (neither the common layer nor
  # the local layer) -- this resource never overrides them, so putting
  # them in a file this resource reads would have silently shipped
  # cmd_local.ml's dev-only values (a 1Gi PVC size vs. the chart's 20Gi
  # default, and an external listener advertising "localhost") to every
  # real terraform apply that doesn't opt into self_hosted_durable.
  # Caught in review; see cmd_local.ml's own comment on its Redpanda install
  # for the full story.
  values = concat(
    local.redpanda_component_values,
    [yamlencode({
      statefulset = { replicas = var.redpanda_replicas }
      config      = { cluster = { write_caching_default = false } }
      resources = {
        cpu    = { cores = var.redpanda_cpu_cores }
        memory = { container = { max = var.redpanda_memory } }
      }
      storage = {
        persistentVolume = { enabled = var.redpanda_persistent_storage }
      }
    })]
  )

  # HARDEN-002 run 2, finding 7: these PVCs name no storageClassName, so they take
  # whatever class is default at admission time. Without this edge Terraform is free
  # to create the StatefulSet first, the claims bind to nothing, and the release
  # times out -- the exact failure finding 7 describes.
  depends_on = [kubernetes_storage_class_v1.platform_default]
}

# ── PostgreSQL (in-cluster; set install_postgresql=false to use RDS/Cloud SQL) #

resource "helm_release" "postgresql" {
  count      = var.install_postgresql ? 1 : 0
  name       = "postgresql"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  # CODE_LAYER-008: was pinned to 15.5.1, which defaults to image tag
  # bitnami/postgresql:16.3.0-debian-12-r12 -- confirmed live (2026-09-06)
  # that tag no longer exists on Docker Hub, so this pin was silently
  # broken for any real `terraform apply` with install_postgresql = true.
  # Bumped to 18.8.17 (appVersion 18.6.0 -- a PostgreSQL 16 -> 18 server
  # major-version jump, not a patch bump).
  #
  # image.tag is left at the chart's own default (`latest`), not pinned to
  # a specific build: confirmed via Docker Hub's API that
  # bitnami/postgresql currently publishes ONLY `latest` (plus
  # signature/attestation/metadata artifacts) -- no versioned tag exists to
  # pin to at all, this is Bitnami's current publishing model for this
  # image (see the chart's own "Rolling tag detected" warning at apply
  # time), not an oversight. This does reopen a narrower version of the
  # exact problem this ticket fixes -- two applies at different times can
  # still pull different PostgreSQL builds even with the chart version
  # pinned -- but there is currently no alternative.
  #
  # DATA SAFETY: this chart bump does not run `pg_upgrade`. An environment
  # with an existing PostgreSQL 16.x persistent volume (var.postgres_persistent_storage
  # = true) will fail to start against 18.x's incompatible data directory
  # format when this pin is adopted -- the volume must be recreated, not
  # upgraded in place. Not a concern for this repo's own ephemeral local/
  # smoke-test clusters, but worth knowing before applying this change
  # against any environment with real persisted data.
  version   = "18.8.17"
  namespace = kubernetes_namespace.postgresql[0].metadata[0].name

  set {
    name  = "auth.postgresPassword"
    value = var.postgres_password
  }
  set {
    name  = "primary.persistence.enabled"
    value = tostring(var.postgres_persistent_storage)
  }

  # CODE_LAYER-010: auth.database now lives in
  # platform/shared/components.json (postgresql.common) (ADR 0001), shared
  # with cmd_local.ml's own PostgreSQL install -- was a hardcoded "dev" `set`
  # in both files independently before. postgresPassword/persistence.enabled
  # stay Terraform-only `set`s: the former is a real secret
  # (var.postgres_password) with no cmd_local.ml equivalent to share, the
  # latter is the same var-driven, no-cmd_local.ml-equivalent case Loki's
  # persistence knob already established above.
  values = local.postgresql_component_values

  # See redpanda above (HARDEN-002 finding 7): default-class ordering.
  depends_on = [kubernetes_storage_class_v1.platform_default]
}

# ── Loki + Grafana + Alloy ──────────────────────────────────────────────── #
#
# OBS-039: loki-stack (deprecated by Grafana Labs, bundled Promtail which
# reached end-of-life March 2026) replaced by the split, currently
# maintained chart set: `loki` (Loki only), `grafana` (standalone, no
# longer a loki-stack subchart), and `alloy` (Promtail's official
# successor, Loki-log-shipping role only -- see alloy/logs.alloy.tftpl).

locals {
  # "external": Alloy ships straight to the user-supplied Loki endpoint; no
  # local Loki/Grafana needed. "local"/"self_hosted_durable": Alloy ships to
  # the in-cluster Loki, which self_hosted_durable then backs with S3
  # instead of local disk.
  loki_install_local = var.observability_backend != "external"

  # Managed resource dashboards (OBS-044) need a real local Grafana to
  # provision into, a real CloudWatch to query, and Grafana's own IRSA role
  # to authenticate -- gate on all three rather than letting the CloudWatch
  # datasource/dashboard ConfigMaps silently no-op on a partial config.
  managed_resource_dashboards_enabled = (
    local.loki_install_local &&
    var.cloud_provider == "aws" &&
    length(var.managed_resource_dashboards) > 0
  )

  managed_resource_types = toset([for r in values(var.managed_resource_dashboards) : r.resource_type])

  # One representative entry per resource_type -- the dashboard template is
  # shaped by resource_type (which CloudWatch namespace/dimension/metric set
  # it queries), not by the specific instance identifier. The instance
  # identifier is resolved live via the dashboard's own "resource" template
  # variable (a CloudWatch dimension_values() query) -- same live-label-
  # driven templating philosophy as the domain/service dashboards' Loki/
  # Prometheus label_values() variables (OBS-011) above.
  managed_resource_by_type = {
    for t in local.managed_resource_types :
    t => [for r in values(var.managed_resource_dashboards) : r if r.resource_type == t][0]
  }

  # ADR 0001 / CODE_LAYER-005: platform/shared/components.json is now the shared
  # source of truth for Helm values that used to be independently
  # hand-duplicated here and in cmd_local.ml (sol local infra up). "local" is the same
  # profile cmd_local.ml uses for its k3d cluster; "durable" is the
  # self_hosted_durable, S3-backed profile. Each component's common layer
  # + values-<profile>.json are read via jsondecode(file(...)) -- per the
  # ADR -- and re-encoded with jsonencode so a malformed JSON file fails
  # `terraform plan`/`validate` instead of surfacing only at `helm upgrade`
  # apply time. Each file is kept as its own entry in the values list rather
  # than merged with Terraform's `merge()` (which is shallow and would drop
  # non-conflicting nested keys on any top-level collision): helm_release's
  # own values list already deep-merges multiple entries in order (see the
  # existing pattern below for helm_release.prometheus), which is exactly
  # the common -> profile -> bindings precedence the ADR specifies.
  # REFAC-102: every component's Helm values in one file, keyed
  # <component>.{common,local,durable} -- by profile, never by env or provider.
  platform_components = jsondecode(file("${path.module}/../../../shared/components.json"))
  # REFAC-101: dashboards and the Alloy config are shared with local dev
  # (Sol_cli_dev_observability reads the same files), so they live outside this module.
  observability_dir     = "${path.module}/../../../shared/observability"
  observability_profile = var.observability_backend == "self_hosted_durable" ? "durable" : "local"
  # CODE_LAYER-010: same value as observability_profile above -- there is
  # currently only one local/durable switch in this module
  # (observability_backend), so Redpanda/PostgreSQL's profile selection
  # necessarily follows it too. Named separately (not just reused
  # directly) so a reader of the two non-observability component blocks
  # below isn't misled into thinking their profile is semantically tied
  # to the observability backend specifically -- it's the platform's one
  # local/durable axis, which today happens to be driven by that one
  # variable. If Redpanda/PostgreSQL ever need their own independent
  # local/durable switch, this is the local to repoint.
  platform_profile = local.observability_profile

  loki_component_values = [
    jsonencode(local.platform_components.loki.common),
    jsonencode(local.platform_components.loki[local.observability_profile]),
  ]
  grafana_component_values = [
    jsonencode(local.platform_components.grafana.common),
    jsonencode(local.platform_components.grafana[local.observability_profile]),
  ]
  tempo_component_values = [
    jsonencode(local.platform_components.tempo.common),
    jsonencode(local.platform_components.tempo[local.observability_profile]),
  ]
  prometheus_component_values = [
    jsonencode(local.platform_components.prometheus.common),
    jsonencode(local.platform_components.prometheus[local.observability_profile]),
  ]
  # CODE_LAYER-010: Redpanda/PostgreSQL have no distinct local/durable
  # branch of their own today (their persistence lives behind separate
  # var.redpanda_persistent_storage/var.postgres_persistent_storage
  # booleans) -- see local.platform_profile above for why this reads that
  # alias rather than observability_profile directly. Both
  # durable layers are empty today; revisit if that ever
  # needs to diverge.
  redpanda_component_values = [
    jsonencode(local.platform_components.redpanda.common),
    jsonencode(local.platform_components.redpanda[local.platform_profile]),
  ]
  postgresql_component_values = [
    jsonencode(local.platform_components.postgresql.common),
    jsonencode(local.platform_components.postgresql[local.platform_profile]),
  ]

  # Alloy's loki.write target -- installed unconditionally (unlike Loki and
  # Grafana), same as promtail.enabled used to be regardless of
  # observability_backend.
  loki_push_url                 = var.observability_backend == "external" ? var.external_loki_url : "http://loki:3100/loki/api/v1/push"
  loki_push_basic_auth_username = var.observability_backend == "external" ? var.external_loki_username : ""
  loki_push_basic_auth_password = var.observability_backend == "external" ? var.external_loki_password : ""

  # OBS-008: promote the label taxonomy (Sol_cli_manifest_yaml's
  # render_taxonomy_labels) from pod labels into Loki stream labels via
  # Alloy's discovery.relabel component -- see alloy/logs.alloy.tftpl.
  observability_taxonomy_labels = ["workspace", "domain", "service", "primitive", "release"]

  # Infrastructure bindings (ADR 0001): the generic "use S3, tsdb schema v13"
  # shape now lives in platform/shared/components.json (loki.durable) --
  # everything left here is Kubernetes-level-only wiring supplied from Layer
  # 1 outputs (an actual bucket name, an actual IAM role ARN), which the ADR
  # says must never be baked into a component's own files. bucketNames/s3
  # addressing confirmed via `helm show values grafana-community/loki
  # --version 18.12.1`; loki_s3_bucket/aws_region/loki_irsa_role_arn come
  # from platform/cloud/aws/cluster's outputs (OBS-006).
  #
  # INFRA-005: the GCP branch fully overrides storage (type: gcs, not s3) and
  # schemaConfig.configs (object_store: gcs) rather than patching just the
  # bucket name -- Helm's chart-values merge replaces lists wholesale rather
  # than merging elements, so schemaConfig.configs must be provided complete
  # whenever overridden. The two branches are kept as separately yamlencode'd
  # strings, chosen by a ternary between the two encoded strings rather than
  # between the two source objects: they have different attribute shapes
  # (storage.s3 vs storage.gcs/schemaConfig), and Terraform's `?:` fails type
  # unification across differently-shaped object literals, whereas the
  # yamlencode'd strings always unify. AWS's branch is byte-for-byte what
  # this local produced before this change.
  loki_infra_bindings_gcs_yaml = yamlencode({
    loki = {
      storage = {
        type = "gcs"
        bucketNames = {
          chunks = var.loki_gcs_bucket
          ruler  = var.loki_gcs_bucket
        }
        gcs = {}
      }
      schemaConfig = {
        configs = [
          {
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "gcs"
            schema       = "v13"
            index        = { prefix = "index_", period = "24h" }
          }
        ]
      }
    }
    serviceAccount = {
      annotations = {
        "iam.gke.io/gcp-service-account" = var.loki_workload_identity_sa_email
      }
    }
  })

  loki_infra_bindings_s3_yaml = yamlencode({
    loki = {
      storage = {
        bucketNames = {
          chunks = var.loki_s3_bucket
          ruler  = var.loki_s3_bucket
        }
        s3 = {
          region           = var.aws_region
          s3ForcePathStyle = false
        }
      }
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = var.loki_irsa_role_arn
      }
    }
  })

  loki_infra_bindings = var.cloud_provider == "gcp" ? local.loki_infra_bindings_gcs_yaml : local.loki_infra_bindings_s3_yaml
}

# Loki-only chart (community-maintained, replacing the deprecated
# loki-stack). No local install for the "external" backend -- there's
# nothing to browse locally when logs ship straight to the user's own
# endpoint. Single Monolithic replica matches loki-stack's single-instance
# footprint ("Dev mirrors prod exactly" -- same shape at both scales).
#
# Chart moved from grafana.github.io/helm-charts to
# grafana-community.github.io/helm-charts (confirmed via `helm search repo`
# against both hosts: the old repo's `grafana/loki` and `grafana/grafana`
# entries are `deprecated: true`; grafana-community's are not). Alloy has
# not moved -- it stays on grafana.github.io/helm-charts, see
# helm_release.alloy below.
resource "helm_release" "loki" {
  count = local.loki_install_local ? 1 : 0

  name       = "loki"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = "18.12.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # Chart shape (Monolithic/1-replica, gateway off, single-tenant,
  # BUG-006/BUG-008/BUG-013's replication_factor: 1 fix, filesystem vs S3
  # storage/schema) now lives in
  # platform/shared/components.json (loki.{common,local,durable})
  # (ADR 0001 / CODE_LAYER-005) -- the same "local" profile file cmd_local.ml's
  # `sol local infra up` reads for its own Loki install, so this no longer needs a
  # parallel, independently-maintained copy (that's the exact gap BUG-016
  # found). See that directory's files for the current values and git blame
  # on this resource for the per-value history that used to live here.
  #
  # Persistence stays a `set` override here: var.loki_persistent_storage is
  # a Terraform-only operator knob with no cmd_local.ml equivalent, and `set`
  # always wins over `values` regardless of which profile file is selected
  # below. the local layer (only) also carries singleBinary.persistence.
  # enabled: false, purely for cmd_local.ml's benefit (it has no var to
  # override with) -- the durable layer deliberately omits this key so
  # there's exactly one place that actually controls persistence for this
  # resource, not two.
  set {
    name  = "singleBinary.persistence.enabled"
    value = tostring(var.loki_persistent_storage)
  }

  values = concat(
    local.loki_component_values,
    var.observability_backend == "self_hosted_durable" ? [local.loki_infra_bindings] : []
  )

  # StorageClass edge: see redpanda above (HARDEN-002 finding 7).
  depends_on = [
    kubernetes_storage_class_v1.platform_default,
    terraform_data.observability_backend_validation
  ]
}

# Grafana, standalone (no longer a loki-stack subchart). Gated identically
# to helm_release.loki -- no local Grafana to browse when shipping to an
# external backend.
resource "helm_release" "grafana" {
  count = local.loki_install_local ? 1 : 0

  name       = "grafana"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = "13.2.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "adminPassword"
    value = var.grafana_admin_password
  }

  # sidecar.dashboards/datasources.enabled (OBS-011: loki-stack's bundled
  # subchart did this implicitly; this standalone chart needs it explicit)
  # now lives in platform/shared/components.json (grafana.common) (ADR 0001 /
  # CODE_LAYER-005), shared with cmd_local.ml's own Grafana install.
  #
  # OBS-044: serviceAccount.annotations is the chart's own documented IRSA
  # example (`helm show values grafana-community/grafana --version 13.2.1`)
  # -- only appended when a managed-resource dashboard actually needs
  # Grafana's pod to authenticate to CloudWatch; every other environment
  # gets the chart's own default (unannotated) ServiceAccount, unchanged.
  values = concat(
    local.grafana_component_values,
    local.managed_resource_dashboards_enabled ? [yamlencode({
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.grafana_irsa_role_arn
        }
      }
    })] : []
  )

  depends_on = [
    terraform_data.observability_backend_validation,
    terraform_data.managed_resource_dashboards_validation,
  ]
}

# CloudWatch datasource for Grafana (OBS-044) -- feeds the managed-resource
# dashboard(s) below. authType "default" uses the AWS SDK's default
# credential chain, which resolves via Grafana's own pod IRSA role
# (helm_release.grafana's serviceAccount annotation above) rather than
# static keys -- same no-static-credentials posture as Loki/Thanos's IRSA
# roles.
resource "kubernetes_config_map" "grafana_cloudwatch_datasource" {
  count = local.managed_resource_dashboards_enabled ? 1 : 0

  metadata {
    name      = "grafana-cloudwatch-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "cloudwatch.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "CloudWatch"
        type   = "cloudwatch"
        access = "proxy"
        jsonData = {
          authType      = "default"
          defaultRegion = var.aws_region
        }
      }]
    })
  }

  depends_on = [helm_release.grafana, terraform_data.managed_resource_dashboards_validation]
}

# Managed resource dashboard(s) (OBS-044) -- one Grafana dashboard per
# distinct resource_type in var.managed_resource_dashboards, rendered from
# the single shared dashboards/managed-resource.json.tftpl template. RDS is
# the only resource_type Sol provisions today (see
# platform/cloud/aws/cluster/main.tf's local.managed_resources); a future managed
# datastore of a new resource_type gets a dashboard the moment it appears in
# managed_resource_dashboards, with no new Terraform resource or template
# needed here.
resource "kubernetes_config_map" "grafana_managed_resource_dashboards" {
  for_each = local.managed_resource_dashboards_enabled ? local.managed_resource_by_type : {}

  metadata {
    name      = "sol-grafana-dashboard-managed-resource-${each.key}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    "managed-resource-${each.key}.json" = templatefile("${local.observability_dir}/dashboards/managed-resource.json.tftpl", {
      resource_type        = each.key
      cloudwatch_namespace = each.value.cloudwatch_namespace
      dimension_name       = each.value.dimension_name
      metrics              = each.value.metrics
      region               = var.aws_region
    })
  }

  depends_on = [helm_release.grafana, terraform_data.managed_resource_dashboards_validation]
}

# Alloy -- Promtail's official successor (Promtail itself reached
# end-of-life March 2026), scoped in this ticket to log shipping only (see
# OBS-039's Non-goal; metrics/traces collection is a future OBS-041
# connection point). Installed unconditionally, matching
# promtail.enabled = true's old unconditional-across-all-backends behavior:
# even the "external" profile needs something scraping and forwarding pod
# logs.
#
# alloy/logs.alloy.tftpl is real Alloy River config (discovery.kubernetes +
# discovery.relabel + loki.source.kubernetes + loki.write), not
# Promtail-shaped YAML -- Alloy's config language has no scrape_configs/
# relabel_configs compatibility surface. loki.source.kubernetes tails pod
# logs via the Kubernetes API rather than a hostPath volume mount, so no
# extra RBAC or `alloy.mounts.*` values are needed beyond this chart's
# default ClusterRole (verified via `helm show values`: the default
# `rbac.rules` already grants `pods`, `pods/log`, and `namespaces`
# get/list/watch).
resource "helm_release" "alloy" {
  name = "alloy"
  # INFRA-032: named by archive URL rather than by repository + version.
  #
  # This is the only chart in this root still sourced from the legacy
  # `grafana.github.io/helm-charts` repository (loki, grafana and tempo all use
  # `grafana-community.github.io/helm-charts`). Rather than serving tarballs at
  # the conventional `<repo>/<chart>-<version>.tgz` path, that legacy index
  # advertises alloy archives on GitHub releases, and the Terraform helm
  # provider resolves the conventional path instead: a 404 HTML page, which
  # surfaces as `could not download chart: Chart.yaml file is missing` and fails
  # the whole platform apply. Reproduced on two independent live targets
  # (HARDEN-002 Run 5 attempts 1 and 2) while every other chart installed.
  #
  # Naming the archive removes repository-index resolution and the off-host URL
  # from the path entirely. `version` is therefore not set: the pin is the URL
  # itself. Verified by installing this exact chart form locally (helm provider
  # 2.17.0, the version this root pins) before use.
  chart     = "https://github.com/grafana/helm-charts/releases/download/alloy-1.12.1/alloy-1.12.1.tgz"
  namespace = kubernetes_namespace.monitoring.metadata[0].name

  values = [yamlencode({
    alloy = {
      configMap = {
        content = templatefile("${local.observability_dir}/alloy/logs.alloy.tftpl", {
          loki_push_url                 = local.loki_push_url
          loki_push_basic_auth_username = local.loki_push_basic_auth_username
          loki_push_basic_auth_password = local.loki_push_basic_auth_password
          taxonomy_labels               = local.observability_taxonomy_labels
        })
      }
    }
  })]

  depends_on = [terraform_data.observability_backend_validation]
}

# Tempo -- distributed tracing (OBS-042). Wired in for -svc only today
# (obs-tempo-eio composed into the scaffold's `-svc` backend, see
# cli/lib/base/sol_cli_scaffold_templates.ml); -worker/-fn are a deliberate
# non-goal, matching OBS-035's own precedent of landing observability
# primitives service-by-service. Gated the same as Loki/Grafana -- no local
# Tempo to receive spans from when there's no local Grafana to browse them
# in either.
#
# grafana-community/tempo (not the deprecated grafana/tempo -- same
# grafana.github.io -> grafana-community.github.io chart move OBS-039 found
# for loki/grafana; confirmed via each repo's index.yaml `deprecated`
# field). "Grafana Tempo Single Binary Mode" is this chart's only mode
# (StatefulSet, replicas: 1 by default) -- unlike loki's SimpleScalable
# default, there is no deploymentMode to zero out. Local disk trace storage
# (the chart's own default `storage.trace.backend: local`) is not
# S3-backed -- a durable path is a future ticket, same gap
# self_hosted_durable's Loki/Thanos S3 backing closes for logs/metrics
# today (see docs/deployment/observability-backends.md).
resource "helm_release" "tempo" {
  count = local.loki_install_local ? 1 : 0

  name       = "tempo"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "tempo"
  version    = "2.3.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # platform/shared/components.json (tempo) has nothing to say today -- both this
  # resource and cmd_local.ml's Tempo install already agreed by relying on the
  # chart's own defaults. Wired up anyway (ADR 0001 / CODE_LAYER-005) so the
  # CI guardrail covers Tempo's next value the same way it now covers
  # Loki/Grafana/Prometheus.
  values = local.tempo_component_values

  depends_on = [terraform_data.observability_backend_validation]
}

# Loki datasource for Grafana. loki-stack's bundled Grafana subchart
# auto-provisioned this itself (a chart-internal template, not just the
# generic sidecar-ConfigMap convention) -- now that Grafana and Loki are
# separate charts with no bundling relationship, that auto-provisioning is
# gone and must be replaced explicitly, the same way
# grafana_prometheus_datasource below already wires up Prometheus. Every
# dashboard in dashboards/*.json references a datasource named exactly
# "Loki".
resource "kubernetes_config_map" "grafana_loki_datasource" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    # OBS-042: derivedFields turns a trace_id in a Loki log line into a
    # click-through to its Tempo waterfall. matcherRegex must match
    # obs-loki-eio's real logfmt output -- trace_id is an unquoted 32-hex-
    # char field (Obs_loki.trace_id_hex, "%016Lx%016Lx"), never quoted since
    # hex digits never trigger Obs_loki.logfmt_val's quoting rule.
    # datasourceUid references kubernetes_config_map.grafana_tempo_datasource's
    # explicit `uid` below -- pinned rather than left for Grafana to derive
    # from the datasource name, so this reference stays stable.
    "loki.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki:3100"
        isDefault = false
        jsonData = {
          derivedFields = [{
            datasourceUid = "tempo"
            matcherRegex  = "trace_id=([0-9a-f]{32})"
            name          = "TraceID"
            url           = "$${__value.raw}"
          }]
        }
      }]
    })
  }

  depends_on = [helm_release.grafana]
}

# Prometheus datasource for Grafana, loaded via the same sidecar-ConfigMap
# mechanism the chart already uses (sidecar.datasources.enabled: true, set
# explicitly on helm_release.grafana above; label key "grafana_datasource"
# is that sidecar's own default, unchanged).
resource "kubernetes_config_map" "grafana_prometheus_datasource" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-prometheus-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "prometheus.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Prometheus"
        type      = "prometheus"
        access    = "proxy"
        url       = "http://prometheus-server.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:80"
        isDefault = false
      }]
    })
  }

  depends_on = [helm_release.grafana]
}

# Tempo datasource for Grafana (OBS-042), loaded via the same sidecar-
# ConfigMap mechanism as Loki/Prometheus above. url targets the query API
# (service port 3200), not the OTLP/HTTP ingestion port (4318) -svc pods
# push spans to -- see helm_release.tempo's comment. `uid` is pinned
# explicitly so kubernetes_config_map.grafana_loki_datasource's
# derivedFields entry above can reference it by a stable value instead of
# whatever Grafana would otherwise derive from the datasource name.
resource "kubernetes_config_map" "grafana_tempo_datasource" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-tempo-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "tempo.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Tempo"
        type      = "tempo"
        access    = "proxy"
        uid       = "tempo"
        url       = "http://tempo.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:3200"
        isDefault = false
      }]
    })
  }

  depends_on = [helm_release.grafana, helm_release.tempo]
}

# OBS-011: the lazy version -- two dashboards total (workspace overview,
# one $domain/$service-templated service dashboard), not one generated file
# per domain/service. Adding a new service requires zero Sol-side dashboard
# changes; Grafana's own template variables (populated from live Prometheus/
# Loki label values, not a static list Sol maintains) do the scoping.
# OBS-036 adds a third, $domain-only dashboard for the gap between
# workspace-wide and single-service views: per-service breakdowns within
# one domain, using the same live-label-driven templating.
# OBS-038 adds a fourth: a deploy/release timeline sourced from OBS-037's
# `event=deploy` Loki log lines (pushed by `sol deploy` itself, not tailed
# from a pod -- those lines carry real stream labels the same way
# application pod logs do, via cmd_deploy_event.ml's own Obs_eio/Obs_loki
# wiring, matching Alloy's taxonomy-label promotion below).
resource "kubernetes_config_map" "grafana_dashboards" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "sol-grafana-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    "workspace-overview.json" = file("${local.observability_dir}/dashboards/workspace-overview.json")
    "service-template.json"   = file("${local.observability_dir}/dashboards/service-template.json")
    "domain-overview.json"    = file("${local.observability_dir}/dashboards/domain-overview.json")
    "release-timeline.json"   = file("${local.observability_dir}/dashboards/release-timeline.json")
  }

  depends_on = [helm_release.grafana]
}

# Grafana Ingress — no local Grafana to expose when shipping to an external
# backend.
resource "kubernetes_ingress_v1" "grafana" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      "cert-manager.io/cluster-issuer"           = var.cluster_issuer
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = ["grafana.${var.base_domain}"]
      secret_name = "grafana-tls"
    }

    rule {
      host = "grafana.${var.base_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "grafana"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.grafana, helm_release.ingress_nginx]
}

# ── Prometheus + Pushgateway ──────────────────────────────────────────────── #

locals {
  prometheus_thanos_enabled = var.observability_backend == "self_hosted_durable"

  prometheus_remote_write = var.observability_backend == "external" ? [
    merge(
      { url = var.external_prometheus_remote_write_url },
      var.external_prometheus_username != "" ? {
        basic_auth = { username = var.external_prometheus_username, password = var.external_prometheus_password }
      } : {}
    )
  ] : []

  # Thanos sidecar shares the prometheus-server pod's own "storage-volume" and
  # uploads TSDB blocks to S3. Thanos Query reads current blocks from the
  # sidecar and historical blocks from storegateway below.
  #
  # Always computed and gated via `concat()` in the values list below, same
  # reasoning as loki_infra_bindings above: a `cond ? {...} : {}` ternary
  # between object literals with different attribute sets fails Terraform's
  # type unification, but list(string) branches never do.
  # INFRA-005: a dynamic map key (not a dual-branch object literal, unlike
  # loki_infra_bindings above) is enough here -- this is the only
  # provider-specific field in an otherwise identical object, so there's no
  # type-unification problem to route around.
  prometheus_thanos_server_fields = {
    server = {
      serviceAccount = {
        annotations = {
          (var.cloud_provider == "gcp" ? "iam.gke.io/gcp-service-account" : "eks.amazonaws.com/role-arn") = (
            var.cloud_provider == "gcp" ? var.thanos_workload_identity_sa_email : var.thanos_irsa_role_arn
          )
        }
      }
      service = {
        gRPC = { enabled = true, servicePort = 10901 }
      }
      extraSecretMounts = [{
        name       = "thanos-objstore-config"
        mountPath  = "/etc/thanos"
        subPath    = ""
        secretName = "thanos-objstore-config"
        readOnly   = true
      }]
      sidecarContainers = {
        thanos-sidecar = {
          image = "thanosio/thanos:v0.35.1"
          args = [
            "sidecar",
            "--tsdb.path=/data",
            "--prometheus.url=http://127.0.0.1:9090",
            "--objstore.config-file=/etc/thanos/objstore.yml",
            "--http-address=0.0.0.0:10902",
            "--grpc-address=0.0.0.0:10901",
          ]
          volumeMounts = [
            { name = "storage-volume", mountPath = "/data" },
            { name = "thanos-objstore-config", mountPath = "/etc/thanos", readOnly = true }
          ]
          ports = [
            { containerPort = 10902, name = "http-sidecar" },
            { containerPort = 10901, name = "grpc" }
          ]
        }
      }
    }
  }
}

# OBS-040: starter alerting rule set. This chart (`prometheus-community/
# prometheus`, plain server + alertmanager -- no Prometheus Operator, so no
# `PrometheusRule` CRD) takes rule/alertmanager config as chart `values`,
# not CRDs. Confirmed against the pinned chart version (25.20.1) via
# `helm show values prometheus-community/prometheus --version 25.20.1`:
#   - `serverFiles.alerting_rules.yml` is the current (non-deprecated) key
#     for Prometheus alerting rules -- a plain `groups: [...]` document,
#     rendered into /etc/config/alerting_rules.yml and wired into
#     prometheus.yml's rule_files by the chart's own default.
#   - Alertmanager is bundled as an actual subchart dependency
#     (`alertmanager` 1.10.*), not the old bundled-values shape --
#     `alertmanagerFiles.alertmanager.yml` is NOT a key this chart version
#     recognizes (confirmed absent from its values.yaml; it would be
#     silently ignored). The subchart's own config lives under the
#     top-level `alertmanager.config` passthrough (same pattern this file
#     already uses for `kube-state-metrics.enabled` below), shaped as
#     `alertmanager` 1.10.0's own `config.route`/`config.receivers` block.
locals {
  # OBS-043: the provider-neutral alert-delivery contract. A target that selects
  # the production profile must declare a receiver/owner/runbook (validated by
  # sol deploy's preflight); applying base with the same values wires the
  # Alertmanager route. Empty values keep the deliberate dev-only null receiver
  # (OBS-040), so local/dev behaves exactly as before.
  alerting_configured = var.alert_receiver_type == "webhook" && var.alert_receiver_url != ""

  # Every required production alert carries its accountable owner and a link to
  # its first-response runbook (OBS-043). Empty in dev, where nothing pages.
  alert_annotations = {
    owner       = var.alert_owner
    runbook_url = var.alert_runbook_url
  }

  # Every rule uses Sol's own label taxonomy (docs/architecture/
  # observability-design.md) or standard kube-state-metrics labels — never a
  # hardcoded domain/service — so the set applies workspace-wide to every
  # deployed workload by default.
  prometheus_alerting_rules = {
    groups = [
      {
        name = "sol-starter-alerts"
        rules = [
          {
            # sol_svc_requests_total / status_class come from sol-svc's own
            # auto-metrics (framework/ocaml/sol-svc/lib/service.ml) and carry the
            # workspace/env/domain/service taxonomy labels via pod-label
            # scraping (Sol_cli_manifest_yaml.render_taxonomy_labels) -- same
            # metric and label set as the "5xx error rate by service" panel in
            # dashboards/domain-overview.json.
            alert = "SolHighErrorRate"
            expr = join(" ", [
              "(sum by (workspace, env, domain, service) (rate(sol_svc_requests_total{status_class=\"5xx\"}[5m]))",
              "/",
              "sum by (workspace, env, domain, service) (rate(sol_svc_requests_total[5m]))) > 0.05"
            ])
            for = "5m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "High 5xx error rate for {{ $labels.service }} ({{ $labels.domain }}/{{ $labels.workspace }})"
              description = "{{ $labels.service }} in domain {{ $labels.domain }} (workspace {{ $labels.workspace }}, env {{ $labels.env }}) has served a 5xx rate of {{ $value | humanizePercentage }} over the last 5 minutes."
            }, local.alert_annotations)
          },
          {
            # kube_pod_container_status_restarts_total comes from
            # kube-state-metrics, bundled and enabled by default in this chart's
            # own subchart defaults (confirmed via `helm show values`:
            # `kube-state-metrics.enabled: true`, not overridden anywhere in this
            # file) and reachable via the chart's default
            # `kubernetes-service-endpoints` scrape job. This metric carries
            # kube-state-metrics' own namespace/pod/container labels, not Sol's
            # taxonomy labels directly (those live on the monitored pod, not on
            # kube-state-metrics' pod) -- Sol namespaces are named
            # `<workspace>-<domain>` (see
            # Sol_cli_kubernetes_name.namespace_of_parts), so the alert is still
            # workspace/domain-identifiable via namespace/pod without a
            # hardcoded value. No `by (...)` grouping needed: the source metric
            # is already per-pod/per-container, not an aggregate.
            alert = "SolPodRestartLoop"
            expr  = "increase(kube_pod_container_status_restarts_total[15m]) > 3"
            for   = "5m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Pod {{ $labels.pod }} restarting repeatedly"
              description = "Container {{ $labels.container }} in pod {{ $labels.pod }} (namespace {{ $labels.namespace }}) restarted {{ $value }} times in the last 15 minutes. Namespace is `<workspace>-<domain>`; join with `kube_pod_labels` for an exact workspace/domain/service breakdown."
            }, local.alert_annotations)
          },
          {
            # OBS-043 indicator 1/5: failed rollout. A Deployment whose available
            # replicas stay below its desired count is either stuck or failing to
            # become ready; `for` keeps an ordinary in-progress rollout from
            # firing. kube-state-metrics, already scraped.
            alert = "SolRolloutFailed"
            expr  = "kube_deployment_status_replicas_available / clamp_min(kube_deployment_spec_replicas, 1) < 1"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Rollout stuck for {{ $labels.namespace }}/{{ $labels.deployment }}"
              description = "Deployment {{ $labels.deployment }} in namespace {{ $labels.namespace }} has had fewer available replicas than desired for 10 minutes."
            }, local.alert_annotations)
          },
          {
            # OBS-043 indicator 2/5: node loss. A node reporting Ready=false (or
            # NotReady) means its workloads are being rescheduled; the
            # `node-failure-tolerant` availability tier assumes enough headroom
            # to absorb this. kube-state-metrics, already scraped.
            alert = "SolNodeNotReady"
            expr  = "kube_node_status_condition{condition=\"Ready\",status=\"true\"} == 0"
            for   = "5m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Node {{ $labels.node }} not ready"
              description = "Node {{ $labels.node }} has reported Ready=false for 5 minutes. Confirm the `node-failure-tolerant` workloads' headroom is absorbing the loss."
            }, local.alert_annotations)
          },
          {
            # OBS-043 indicator 5/5: telemetry loss. DEC-026 §5 makes telemetry
            # the deliberately weakest contract, so this alert states an explicit
            # degraded mode: alerting/dashboards are compromised while the
            # business data path is not. Any monitoring-namespace scrape target
            # being down is the signal.
            alert = "SolTelemetryTargetDown"
            expr  = "up{namespace=\"monitoring\"} == 0"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Telemetry target down in monitoring"
              description = "Scrape target {{ $labels.job }} ({{ $labels.instance }}) in the monitoring namespace has been down for 10 minutes. Diagnostics are degraded; business-data durability is unaffected (DEC-026 §5)."
            }, local.alert_annotations)
          },
          {
            # OBS-043 indicator 3/5: Postgres dependency loss/restore. Requires a
            # target-provided Postgres exporter (`pg_up`); silent, never a false
            # positive, when no such target is scraped. The managed-RDS path
            # exports via OBS-044's CloudWatch integration rather than this rule.
            alert = "SolPostgresUnavailable"
            expr  = "pg_up == 0"
            for   = "5m"
            labels = {
              severity = "critical"
            }
            annotations = merge({
              summary     = "Postgres dependency unavailable"
              description = "The monitored Postgres target has been down for 5 minutes. Restore/failover runbook applies; application writes may be failing."
            }, local.alert_annotations)
          },
          {
            # OBS-043 indicator 4/5: Kafka lag/broker loss (two signals). Both
            # are Redpanda's own metrics; silent when Redpanda is not scraped.
            # The thresholds are deliberately conservative starting points.
            alert = "SolKafkaConsumerLagHigh"
            expr  = "redpanda_kafka_consumer_group_lag > 10000"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Kafka consumer lag high for group {{ $labels.group }}"
              description = "Consumer group {{ $labels.group }} on topic {{ $labels.topic }} has been more than 10000 messages behind for 10 minutes."
            }, local.alert_annotations)
          },
          {
            # OBS-047 / FND-0049: the three worker signals that messages are being
            # dropped or diverted rather than processed. All come from sol-worker's
            # own auto-metrics (framework/ocaml/sol-worker, kafka-eio-service) and
            # carry the workspace/env/domain/service taxonomy through pod-label
            # scraping, like SolHighErrorRate. Consumer lag alone cannot see these:
            # a worker acking poison messages keeps lag at zero.
            #
            # A decode failure on the source topic is lost input for this group:
            # dead-lettered under Retry_topics (BUG-051), acked and dropped under
            # In_memory or an explicit Ack_and_drop. Either way, not a transient.
            alert = "SolWorkerDecodeDrops"
            expr  = "sum by (workspace, env, domain, service) (increase(sol_worker_decode_errors_total[5m])) > 0"
            for   = "0s"
            labels = {
              severity = "critical"
            }
            annotations = merge({
              summary     = "{{ $labels.service }} could not decode messages ({{ $labels.domain }}/{{ $labels.workspace }})"
              description = "{{ $labels.service }} in domain {{ $labels.domain }} (workspace {{ $labels.workspace }}, env {{ $labels.env }}) could not decode about {{ $value | humanize }} message(s) in the last 5 minutes; they were dead-lettered (Retry_topics) or acked and dropped. Usually a producer deployed an incompatible schema."
            }, local.alert_annotations)
          },
          {
            # relay_failed: a retry/DLQ publish exhausted its in-process retries,
            # so retry delivery is failing (BUG-029's metric-level signal).
            # A value test, not increase(): the labelled series does not exist
            # until its first failure, so it first appears already at 1, which
            # increase() never counts. The relay also stops after that failure,
            # so the count does not rise again. "Nonzero since this pod started"
            # is the signal, and a restart resets it.
            alert = "SolWorkerRelayPublishFailed"
            expr  = "sum by (workspace, env, domain, service) (sol_worker_messages_total{status=\"relay_failed\"}) > 0"
            for   = "0s"
            labels = {
              severity = "critical"
            }
            annotations = merge({
              summary     = "{{ $labels.service }} cannot publish to its retry/DLQ topics ({{ $labels.domain }}/{{ $labels.workspace }})"
              description = "{{ $labels.service }} in domain {{ $labels.domain }} (workspace {{ $labels.workspace }}, env {{ $labels.env }}) failed {{ $value | humanize }} retry/DLQ publish(es) after exhausting in-process retries since the pod started. The records stay unacknowledged; retry delivery is not progressing."
            }, local.alert_annotations)
          },
          {
            # dead_letter: work the handler declared unprocessable. A trickle can be
            # normal; a sustained stream is a failing dependency or a bad deploy.
            alert = "SolWorkerDeadLetterInflow"
            expr  = "sum by (workspace, env, domain, service) (rate(sol_worker_messages_total{status=\"dead_letter\"}[10m])) > 0"
            for   = "15m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "{{ $labels.service }} is dead-lettering messages ({{ $labels.domain }}/{{ $labels.workspace }})"
              description = "{{ $labels.service }} in domain {{ $labels.domain }} (workspace {{ $labels.workspace }}, env {{ $labels.env }}) has sent messages to its DLQ continuously for 15 minutes ({{ $value | humanize }}/s)."
            }, local.alert_annotations)
          },
          {
            alert = "SolKafkaBrokerDown"
            expr  = "up{job=~\".*redpanda.*\"} == 0"
            for   = "5m"
            labels = {
              severity = "critical"
            }
            annotations = merge({
              summary     = "Kafka broker scrape target down"
              description = "A Redpanda broker scrape target ({{ $labels.instance }}) has been down for 5 minutes. The `single-broker-loss` durability contract tolerates one broker; more than one is outside the profile."
            }, local.alert_annotations)
          }
        ]
      }
    ]
  }

  # Null receiver by default (OBS-040): a "null" receiver (declared, zero
  # configs) still shows fired/resolved alerts in Alertmanager's own UI/API, it
  # just sends nothing anywhere. When the target declares the OBS-043 webhook
  # contract, route every alert to it. Slack/PagerDuty/email remain documented
  # adapters over the same provider-neutral contract; none is the Sol semantic.
  prometheus_alertmanager_config = local.alerting_configured ? {
    route = {
      receiver        = "sol-receiver"
      group_by        = ["alertname", "workspace", "domain", "service"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
    }
    receivers = [
      {
        name = "sol-receiver"
        webhook_configs = [{
          url           = var.alert_receiver_url
          send_resolved = true
        }]
      }
    ]
    } : {
    route = {
      receiver        = "null"
      group_by        = ["alertname", "workspace", "domain", "service"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
    }
    receivers = [
      # HARDEN-002 (run 2): the unconfigured branch must carry the *same*
      # attribute set as the configured one. Terraform unifies the two branches
      # of a conditional by object shape, so `{ name = "null" }` against
      # `{ name = ..., webhook_configs = [...] }` was an
      # "Inconsistent conditional result types" error -- and because
      # local.alerting_configured is true exactly when a receiver is declared,
      # which the production profile requires, the whole base platform was
      # unappliable for a conformant target. A null receiver with no
      # integrations is valid Alertmanager configuration.
      { name = "null", webhook_configs = [] }
    ]
  }
}

# Thanos's object-store config file, mounted into the sidecar and Bitnami
# Thanos components. IRSA/Workload Identity supplies credentials; no access
# keys in this config either way.
#
# INFRA-005: the two branches are separately yamlencode'd (S3's config has
# bucket/endpoint/region, GCS's just bucket -- genuinely different shapes),
# chosen by a ternary between the encoded strings rather than the source
# objects, same reasoning as loki_infra_bindings above.
resource "kubernetes_secret" "thanos_objstore_config" {
  count = local.prometheus_thanos_enabled ? 1 : 0

  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "objstore.yml" = var.cloud_provider == "gcp" ? yamlencode({
      type = "GCS"
      config = {
        bucket = var.thanos_gcs_bucket
      }
      }) : yamlencode({
      type = "S3"
      config = {
        bucket   = var.thanos_s3_bucket
        endpoint = "s3.${var.aws_region}.amazonaws.com"
        region   = var.aws_region
      }
    })
  }
}

resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = "25.20.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # Persistence stays a `set` override here, same reasoning as Loki's
  # singleBinary.persistence.enabled above: var.prometheus_persistent_storage
  # is a Terraform-only operator knob with no cmd_local.ml equivalent, and
  # `set` always wins over `values` regardless of which profile file is
  # selected. the local layer (only) also carries
  # server.persistentVolume.enabled: false, purely for cmd_local.ml's benefit
  # (it has no var to override with) -- the durable layer deliberately
  # omits this key so there's exactly one place that actually controls
  # persistence for this resource, not two.
  set {
    name  = "server.persistentVolume.enabled"
    value = tostring(var.observability_backend == "external" ? false : var.prometheus_persistent_storage)
  }
  set {
    name = "server.retention"
    # "external": local storage is just a remote_write buffer, not the
    # durable store, so a short retention is enough.
    value = var.observability_backend == "external" ? "2h" : "15d"
  }

  # pushgateway.enabled/alertmanager.enabled now live in
  # platform/shared/components.json (prometheus.common) (ADR 0001 /
  # CODE_LAYER-005), shared with cmd_local.ml's own Prometheus install --
  # previously `true` here unconditionally and relied on as the chart's own
  # default over in cmd_local.ml, so making both paths state it explicitly
  # from one file removes an implicit-default-drift risk without changing
  # either path's actual behavior.
  values = concat(
    local.prometheus_component_values,
    [yamlencode({ server = { remoteWrite = local.prometheus_remote_write } })],
    local.prometheus_thanos_enabled ? [yamlencode(local.prometheus_thanos_server_fields)] : [],
    [yamlencode({ serverFiles = { "alerting_rules.yml" = local.prometheus_alerting_rules } })],
    [yamlencode({ alertmanager = { config = local.prometheus_alertmanager_config } })]
  )

  # StorageClass edge: see redpanda above (HARDEN-002 finding 7).
  depends_on = [
    kubernetes_storage_class_v1.platform_default,
    kubernetes_secret.thanos_objstore_config,
    terraform_data.observability_backend_validation
  ]
}

# Thanos read path for durable metrics. Keep it to the components needed for
# queryable history: query, storegateway, and compactor.
resource "helm_release" "thanos" {
  count      = local.prometheus_thanos_enabled ? 1 : 0
  name       = "thanos"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "thanos"
  version    = "17.3.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "query.enabled"
    value = "true"
  }
  set {
    name  = "query.dnsDiscovery.enabled"
    value = "false"
  }
  set {
    name  = "query.stores[0]"
    value = "prometheus-server.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:10901"
  }
  set {
    name  = "query.stores[1]"
    value = "thanos-storegateway.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:10901"
  }
  set {
    name  = "existingObjstoreSecret"
    value = kubernetes_secret.thanos_objstore_config[0].metadata[0].name
  }
  set {
    name  = "storegateway.enabled"
    value = "true"
  }
  set {
    name  = "compactor.enabled"
    value = "true"
  }
  set {
    name  = "compactor.retentionResolutionRaw"
    value = "${var.prometheus_raw_retention_days}d"
  }
  set {
    name  = "compactor.retentionResolution5m"
    value = "${var.thanos_retention_5m_days}d"
  }
  set {
    name  = "compactor.retentionResolution1h"
    value = "${var.thanos_retention_1h_days}d"
  }
  # INFRA-005: `set`'s name/value are ordinary string expressions, so a
  # ternary works here the same as everywhere else in this file -- the dotted
  # annotation key is escaped either way (Helm's --set path syntax), just a
  # different key/value pair per provider.
  set {
    name = (
      var.cloud_provider == "gcp"
      ? "storegateway.serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
      : "storegateway.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    )
    value = var.cloud_provider == "gcp" ? var.thanos_workload_identity_sa_email : var.thanos_irsa_role_arn
  }
  set {
    name = (
      var.cloud_provider == "gcp"
      ? "compactor.serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
      : "compactor.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    )
    value = var.cloud_provider == "gcp" ? var.thanos_workload_identity_sa_email : var.thanos_irsa_role_arn
  }
  set {
    name  = "receive.enabled"
    value = "false"
  }
  set {
    name  = "ruler.enabled"
    value = "false"
  }
  set {
    name  = "bucketweb.enabled"
    value = "false"
  }
  set {
    name  = "queryFrontend.enabled"
    value = "false"
  }

  depends_on = [
    helm_release.prometheus,
    terraform_data.observability_backend_validation
  ]
}

# HARDEN-002 run 2, finding 7: the default StorageClass the platform's own
# durable components need. Before this, Redpanda's PVCs had no class to bind to
# and the brokers sat Pending until the Helm release timed out, so the profile's
# durability claims had no substrate support at all.
#
# WaitForFirstConsumer matches EBS's zonal nature: the volume is created in the
# zone the pod lands in, rather than pinning a broker to a zone chosen at claim
# time.
#
# AWS only, and deliberately so. The platform's PVCs name no storageClassName
# (see the Redpanda and Loki releases above), so they take the cluster's *default*
# class; EKS ships none, so Sol has to create one. GKE ships `standard-rwo`
# (`pd.csi.storage.gke.io`) already annotated as the default, so on GCP Sol adopts
# the provider's class instead -- creating a second default would leave the
# cluster with two, which Kubernetes accepts with a warning and then resolves
# arbitrarily. `Ready` asserts the outcome either way: the provider's class is the
# sole default and is backed by the provider's block-storage CSI driver
# (Sol_cli_cloud_lifecycle.platform_storage).
resource "kubernetes_storage_class_v1" "platform_default" {
  count = var.create_storage_class && var.cloud_provider == "aws" ? 1 : 0

  metadata {
    name        = var.storage_class_name
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
    # These volumes hold the platform's durable data -- Redpanda's log, in-cluster
    # Postgres, Loki chunks, the Prometheus TSDB -- so they carry the same at-rest
    # posture as the rest of the substrate (aws_db_instance.postgres is
    # storage_encrypted, the state bucket is AES256, EKS secrets are KMS-enveloped).
    # Encryption-by-default is an account setting Sol does not own, so stating it
    # here is what makes it true on any account. The AWS-managed aws/ebs key needs
    # no extra grant; a customer-managed key would need kmsKeyId and an IRSA grant.
    encrypted = "true"
  }
}
