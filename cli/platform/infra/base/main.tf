# cli/platform/infra/base — cluster-agnostic platform bootstrap
#
# Installs all Sol platform components onto an existing Kubernetes cluster
# using Helm. Run this once per cluster after provisioning (cli/platform/infra/aws or
# cli/platform/infra/gcp). The cluster kubeconfig must be active before applying.
#
# Components installed:
#   cert-manager       — TLS certificate automation (Let's Encrypt)
#   ingress-nginx      — Ingress controller
#   Argo CD            — GitOps continuous delivery
#   Redpanda           — Kafka-compatible broker + schema registry
#   PostgreSQL         — Primary database (use cli/platform/infra/aws RDS for production)
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
      condition = var.observability_backend != "self_hosted_durable" || (
        trimspace(var.loki_s3_bucket) != "" &&
        trimspace(var.loki_irsa_role_arn) != "" &&
        trimspace(var.thanos_s3_bucket) != "" &&
        trimspace(var.thanos_irsa_role_arn) != ""
      )
      error_message = "observability_backend = \"self_hosted_durable\" requires loki_s3_bucket, loki_irsa_role_arn, thanos_s3_bucket, and thanos_irsa_role_arn."
    }

    precondition {
      condition     = var.observability_backend != "self_hosted_durable" || var.cloud_provider == "aws"
      error_message = "observability_backend = \"self_hosted_durable\" is currently supported only on AWS/EKS because it uses IRSA. GCP support requires Workload Identity wiring."
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
      error_message = "managed_resource_dashboards requires grafana_irsa_role_arn (from cli/platform/infra/aws's grafana_irsa_arn output) so Grafana's CloudWatch datasource can authenticate."
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
  # (values-common.json, a chart values.schema.json workaround) -- on an
  # already-deployed environment, `terraform apply` tears Redpanda Console's
  # Deployment/Service/ConfigMap/ServiceAccount down, not just skips installing
  # them. Verified safe (ClusterIP-only, no ingress, nothing in Sol references
  # it), but a real operator diffing a real plan should expect that deletion.
  # Keep this in sync with cmd_local.ml's pin (CODE_LAYER-008).
  version   = "26.1.11"
  namespace = kubernetes_namespace.redpanda.metadata[0].name
  timeout   = 600

  # CODE_LAYER-010: tls.enabled/config.cluster.auto_create_topics_enabled
  # now live in cli/platform/components/redpanda/values-common.json (ADR 0001),
  # shared with cmd_local.ml's own Redpanda install. statefulset.replicas/
  # resources.cpu.cores also appear in values-local.json (for cmd_local.ml's
  # benefit only) but are safely overridden here regardless, since this
  # block is the LAST entry in the values list. What's left here
  # (replicas/cpu/memory/persistence) is genuinely Terraform-only --
  # driven by operator variables cmd_local.ml has no equivalent for, same
  # reasoning as Loki's singleBinary.persistence.enabled `set` above.
  #
  # storage.persistentVolume.size and cmd_local.ml's external.*/
  # listeners.kafka.* block are deliberately NOT in
  # cli/platform/components/redpanda/ at all (neither values-common.json nor
  # values-local.json) -- this resource never overrides them, so putting
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
      resources = {
        cpu    = { cores = var.redpanda_cpu_cores }
        memory = { container = { max = var.redpanda_memory } }
      }
      storage = {
        persistentVolume = { enabled = var.redpanda_persistent_storage }
      }
    })]
  )
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
  # cli/platform/components/postgresql/values-common.json (ADR 0001), shared
  # with cmd_local.ml's own PostgreSQL install -- was a hardcoded "dev" `set`
  # in both files independently before. postgresPassword/persistence.enabled
  # stay Terraform-only `set`s: the former is a real secret
  # (var.postgres_password) with no cmd_local.ml equivalent to share, the
  # latter is the same var-driven, no-cmd_local.ml-equivalent case Loki's
  # persistence knob already established above.
  values = local.postgresql_component_values
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

  # ADR 0001 / CODE_LAYER-005: cli/platform/components/<name>/ is now the shared
  # source of truth for Helm values that used to be independently
  # hand-duplicated here and in cmd_local.ml (sol dev up). "local" is the same
  # profile cmd_local.ml uses for its k3d cluster; "durable" is the
  # self_hosted_durable, S3-backed profile. Each component's values-common
  # + values-<profile>.json are read via jsondecode(file(...)) -- per the
  # ADR -- and re-encoded with jsonencode so a malformed JSON file fails
  # `terraform plan`/`validate` instead of surfacing only at `helm upgrade`
  # apply time. Each file is kept as its own entry in the values list rather
  # than merged with Terraform's `merge()` (which is shallow and would drop
  # non-conflicting nested keys on any top-level collision): helm_release's
  # own values list already deep-merges multiple entries in order (see the
  # existing pattern below for helm_release.prometheus), which is exactly
  # the common -> profile -> bindings precedence the ADR specifies.
  platform_components_dir = "${path.module}/../../components"
  observability_profile   = var.observability_backend == "self_hosted_durable" ? "durable" : "local"
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
    jsonencode(jsondecode(file("${local.platform_components_dir}/loki/values-common.json"))),
    jsonencode(jsondecode(file("${local.platform_components_dir}/loki/values-${local.observability_profile}.json"))),
  ]
  grafana_component_values = [
    jsonencode(jsondecode(file("${local.platform_components_dir}/grafana/values-common.json"))),
    jsonencode(jsondecode(file("${local.platform_components_dir}/grafana/values-${local.observability_profile}.json"))),
  ]
  tempo_component_values = [
    jsonencode(jsondecode(file("${local.platform_components_dir}/tempo/values-common.json"))),
    jsonencode(jsondecode(file("${local.platform_components_dir}/tempo/values-${local.observability_profile}.json"))),
  ]
  prometheus_component_values = [
    jsonencode(jsondecode(file("${local.platform_components_dir}/prometheus/values-common.json"))),
    jsonencode(jsondecode(file("${local.platform_components_dir}/prometheus/values-${local.observability_profile}.json"))),
  ]
  # CODE_LAYER-010: Redpanda/PostgreSQL have no distinct local/durable
  # branch of their own today (their persistence lives behind separate
  # var.redpanda_persistent_storage/var.postgres_persistent_storage
  # booleans) -- see local.platform_profile above for why this reads that
  # alias rather than observability_profile directly. Both
  # values-durable.json files are empty today; revisit if that ever
  # needs to diverge.
  redpanda_component_values = [
    jsonencode(jsondecode(file("${local.platform_components_dir}/redpanda/values-common.json"))),
    jsonencode(jsondecode(file("${local.platform_components_dir}/redpanda/values-${local.platform_profile}.json"))),
  ]
  postgresql_component_values = [
    jsonencode(jsondecode(file("${local.platform_components_dir}/postgresql/values-common.json"))),
    jsonencode(jsondecode(file("${local.platform_components_dir}/postgresql/values-${local.platform_profile}.json"))),
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
  # shape now lives in cli/platform/components/loki/values-durable.json --
  # everything left here is Kubernetes-level-only wiring supplied from Layer
  # 1 outputs (an actual bucket name, an actual IAM role ARN), which the ADR
  # says must never be baked into a component's own files. bucketNames/s3
  # addressing confirmed via `helm show values grafana-community/loki
  # --version 18.12.1`; loki_s3_bucket/aws_region/loki_irsa_role_arn come
  # from cli/platform/infra/aws's outputs (OBS-006).
  loki_infra_bindings = {
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
  }
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
  # cli/platform/components/loki/{values-common,values-local,values-durable}.json
  # (ADR 0001 / CODE_LAYER-005) -- the same "local" profile file cmd_local.ml's
  # `sol dev up` reads for its own Loki install, so this no longer needs a
  # parallel, independently-maintained copy (that's the exact gap BUG-016
  # found). See that directory's files for the current values and git blame
  # on this resource for the per-value history that used to live here.
  #
  # Persistence stays a `set` override here: var.loki_persistent_storage is
  # a Terraform-only operator knob with no cmd_local.ml equivalent, and `set`
  # always wins over `values` regardless of which profile file is selected
  # below. values-local.json (only) also carries singleBinary.persistence.
  # enabled: false, purely for cmd_local.ml's benefit (it has no var to
  # override with) -- values-durable.json deliberately omits this key so
  # there's exactly one place that actually controls persistence for this
  # resource, not two.
  set {
    name  = "singleBinary.persistence.enabled"
    value = tostring(var.loki_persistent_storage)
  }

  values = concat(
    local.loki_component_values,
    var.observability_backend == "self_hosted_durable" ? [yamlencode(local.loki_infra_bindings)] : []
  )

  depends_on = [terraform_data.observability_backend_validation]
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
  # now lives in cli/platform/components/grafana/values-common.json (ADR 0001 /
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
# cli/platform/infra/aws/main.tf's local.managed_resources); a future managed
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
    "managed-resource-${each.key}.json" = templatefile("${path.module}/dashboards/managed-resource.json.tftpl", {
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
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "1.12.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [yamlencode({
    alloy = {
      configMap = {
        content = templatefile("${path.module}/alloy/logs.alloy.tftpl", {
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
# cli/sol/lib/sol_cli_scaffold_templates.ml); -worker/-fn are a deliberate
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

  # cli/platform/components/tempo/ has nothing to say today -- both this
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
    "workspace-overview.json" = file("${path.module}/dashboards/workspace-overview.json")
    "service-template.json"   = file("${path.module}/dashboards/service-template.json")
    "domain-overview.json"    = file("${path.module}/dashboards/domain-overview.json")
    "release-timeline.json"   = file("${path.module}/dashboards/release-timeline.json")
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
  prometheus_thanos_server_fields = {
    server = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.thanos_irsa_role_arn
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
  # Both rules use Sol's own label taxonomy (docs/architecture/
  # observability-design.md) rather than a hardcoded domain/service, so
  # they apply workspace-wide to every deployed service by default.
  prometheus_alerting_rules = {
    groups = [
      {
        name = "sol-starter-alerts"
        rules = [
          {
            # sol_svc_requests_total / status_class come from sol-svc's own
            # auto-metrics (framework/sol-svc/lib/service.ml) and carry the
            # workspace/env/domain/service taxonomy labels via pod-label
            # scraping (Sol_cli_manifest_yaml.render_taxonomy_labels) --
            # same metric and label set as the "5xx error rate by service"
            # panel in dashboards/domain-overview.json.
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
            annotations = {
              summary     = "High 5xx error rate for {{ $labels.service }} ({{ $labels.domain }}/{{ $labels.workspace }})"
              description = "{{ $labels.service }} in domain {{ $labels.domain }} (workspace {{ $labels.workspace }}, env {{ $labels.env }}) has served a 5xx rate of {{ $value | humanizePercentage }} over the last 5 minutes."
            }
          },
          {
            # kube_pod_container_status_restarts_total comes from
            # kube-state-metrics, bundled and enabled by default in this
            # chart's own subchart defaults (confirmed via `helm show
            # values`: `kube-state-metrics.enabled: true`, not overridden
            # anywhere in this file) and reachable via the chart's default
            # `kubernetes-service-endpoints` scrape job. This metric
            # carries kube-state-metrics' own namespace/pod/container
            # labels, not Sol's taxonomy labels directly (those live on
            # the monitored pod, not on kube-state-metrics' pod) -- Sol
            # namespaces are named `<workspace>-<domain>` (see
            # Sol_cli_kubernetes_name.namespace_of_parts), so the alert is
            # still workspace/domain-identifiable via namespace/pod
            # without a hardcoded value. No `by (...)` grouping needed:
            # the source metric is already per-pod/per-container, not an
            # aggregate.
            alert = "SolPodRestartLoop"
            expr  = "increase(kube_pod_container_status_restarts_total[15m]) > 3"
            for   = "5m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary     = "Pod {{ $labels.pod }} restarting repeatedly"
              description = "Container {{ $labels.container }} in pod {{ $labels.pod }} (namespace {{ $labels.namespace }}) restarted {{ $value }} times in the last 15 minutes. Namespace is `<workspace>-<domain>`; join with `kube_pod_labels` for an exact workspace/domain/service breakdown."
            }
          }
        ]
      }
    ]
  }

  # No notification receiver by default -- a "null" receiver (declared,
  # zero configs) still shows fired/resolved alerts in Alertmanager's own
  # UI/API, it just sends nothing anywhere. Pointing this at a real
  # Slack/PagerDuty/email receiver is documented as a per-user override in
  # docs/deployment/observability-backends.md, not shipped here.
  prometheus_alertmanager_config = {
    route = {
      receiver        = "null"
      group_by        = ["alertname", "workspace", "domain", "service"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
    }
    receivers = [
      { name = "null" }
    ]
  }
}

# Thanos's object-store config file, mounted into the sidecar and Bitnami
# Thanos components. IRSA supplies credentials; no access keys in this config.
resource "kubernetes_secret" "thanos_objstore_config" {
  count = local.prometheus_thanos_enabled ? 1 : 0

  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "objstore.yml" = yamlencode({
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
  # selected. values-local.json (only) also carries
  # server.persistentVolume.enabled: false, purely for cmd_local.ml's benefit
  # (it has no var to override with) -- values-durable.json deliberately
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
  # cli/platform/components/prometheus/values-common.json (ADR 0001 /
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

  depends_on = [
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
  set {
    name  = "storegateway.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.thanos_irsa_role_arn
  }
  set {
    name  = "compactor.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.thanos_irsa_role_arn
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
