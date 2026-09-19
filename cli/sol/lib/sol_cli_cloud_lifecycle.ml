type aws_outputs =
  { cluster_name : string
  ; provisioner_role_arn : string
  ; cert_manager_irsa_role_arn : string
  ; loki_s3_bucket : string option
  ; loki_irsa_role_arn : string option
  ; thanos_s3_bucket : string option
  ; thanos_irsa_role_arn : string option
  ; grafana_irsa_role_arn : string option
  ; managed_resource_dashboards : Yojson.Safe.t
  }

let backend_config (target : Sol_cli_config.target) ~root =
  match target.state_bucket, target.state_lock_table with
  | Some bucket, Some table when String.trim bucket <> "" && String.trim table <> "" ->
    let layer =
      match root with
      | `Cloud -> "cloud"
      | `Platform -> "platform"
    in
    Ok
      [ "bucket=" ^ String.trim bucket
      ; Printf.sprintf "key=sol/%s/%s.tfstate" target.name layer
      ; "region=" ^ target.region
      ; "dynamodb_table=" ^ String.trim table
      ; "encrypt=true"
      ]
  | _ ->
    Error
      "target must declare state_bucket and state_lock_table before `sol cloud` can use \
       durable state"
;;

type aws_target =
  { target : Sol_cli_config.target
  ; cloud_backend : string list
  ; platform_backend : string list
  ; base_domain : string
  ; letsencrypt_email : string
  ; provisioner_role_arn : string
  }

let required name = function
  | Some value when String.trim value <> "" -> Ok (String.trim value)
  | _ -> Error ("AWS cloud lifecycle requires target." ^ name)
;;

let aws_target target =
  let ( let* ) = Result.bind in
  let* cloud_backend = backend_config target ~root:`Cloud in
  let* platform_backend = backend_config target ~root:`Platform in
  let* base_domain = required "base_domain" target.Sol_cli_config.base_domain in
  let* letsencrypt_email = required "letsencrypt_email" target.letsencrypt_email in
  let* provisioner_role_arn =
    required "provisioner_role_arn" target.provisioner_role_arn
  in
  Ok
    { target
    ; cloud_backend
    ; platform_backend
    ; base_domain
    ; letsencrypt_email
    ; provisioner_role_arn
    }
;;

let target config = config.target
let cloud_backend config = config.cloud_backend
let platform_backend config = config.platform_backend

let aws_outputs_of_json text =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string text in
    (* HARDEN-002 run 3, finding 10: Terraform *omits* an output whose value is
       `null` (v1.9.8), rather than emitting it as present-with-null. So an
       optional output such as `loki_s3_bucket` (null unless durable
       observability is enabled) can be absent entirely. `member` yields `Null`
       for a missing key, and `member "value"` on `Null` raises; resolve an
       absent output to `Null` so `optional_string` treats it exactly like a
       null value, while a *required* output still fails closed with a named
       "missing or not a string" error rather than crashing the lifecycle. *)
    let value name =
      match json |> member name with
      | `Null -> `Null
      | output -> output |> member "value"
    in
    let string name =
      match value name with
      | `String s when String.trim s <> "" -> Ok s
      | _ ->
        Error (Printf.sprintf "AWS Terraform output %S is missing or not a string" name)
    in
    let optional_string name =
      match value name with
      | `Null -> Ok None
      | `String s -> Ok (if String.trim s = "" then None else Some s)
      | _ -> Error (Printf.sprintf "AWS Terraform output %S is not a string or null" name)
    in
    let ( let* ) = Result.bind in
    let* cluster_name = string "cluster_name" in
    let* provisioner_role_arn = string "provisioner_role_arn" in
    let* cert_manager_irsa_role_arn = string "cert_manager_irsa_arn" in
    let* loki_s3_bucket = optional_string "loki_s3_bucket" in
    let* loki_irsa_role_arn = optional_string "loki_irsa_arn" in
    let* thanos_s3_bucket = optional_string "thanos_s3_bucket" in
    let* thanos_irsa_role_arn = optional_string "thanos_irsa_arn" in
    let* grafana_irsa_role_arn = optional_string "grafana_irsa_arn" in
    let managed_resource_dashboards = value "managed_resource_dashboards" in
    match managed_resource_dashboards with
    | `Assoc _ ->
      Ok
        { cluster_name
        ; provisioner_role_arn
        ; cert_manager_irsa_role_arn
        ; loki_s3_bucket
        ; loki_irsa_role_arn
        ; thanos_s3_bucket
        ; thanos_irsa_role_arn
        ; grafana_irsa_role_arn
        ; managed_resource_dashboards
        }
    | _ -> Error "AWS Terraform output \"managed_resource_dashboards\" is not an object"
  with
  | Yojson.Json_error message -> Error ("invalid AWS Terraform output JSON: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    Error ("invalid AWS Terraform outputs: " ^ message)
;;

let cluster_name outputs = outputs.cluster_name
let provisioner_role_arn (outputs : aws_outputs) = outputs.provisioner_role_arn

(* HARDEN-002 run 4, finding 12. The base-platform providers are hashicorp/
   kubernetes and hashicorp/helm, configured implicitly (cli/platform/infra/base
   declares no `provider` block). hashicorp/kubernetes 2.38.0 resolves the
   kubeconfig from `KUBE_CONFIG_PATH`/`KUBE_CONFIG_PATHS` and falls back to
   `~/.kube/config` -- it does NOT consult `KUBECONFIG`, which is the only name
   Sol used to export. So the platform phase silently used the operator's
   ambient kubeconfig (or none) and could not reach the provisioned cluster
   (`dial tcp 127.0.0.1:80`). Export every name the providers read, all pointing
   at the same ephemeral provisioner kubeconfig, so the phase is deterministic
   and never ambient. *)
let provisioner_kube_env path =
  [ "KUBECONFIG", path; "KUBE_CONFIG_PATH", path; "KUBE_CONFIG_PATHS", path ]
;;

type platform_inputs =
  { base_domain : string
  ; letsencrypt_email : string
  ; region : string
  ; cluster_issuer : string option
  ; observability_backend : string option
  ; alert_receiver_type : string option
  ; alert_receiver_url : string option
  ; alert_owner : string option
  ; alert_runbook_url : string option
  ; outputs : aws_outputs
  }

let platform_inputs (target : aws_target) (outputs : aws_outputs) =
  if outputs.provisioner_role_arn <> target.provisioner_role_arn
  then Error "AWS provisioner_role_arn output does not match the validated target"
  else
    Ok
      { base_domain = target.base_domain
      ; letsencrypt_email = target.letsencrypt_email
      ; region = target.target.region
      ; cluster_issuer = target.target.cluster_issuer
      ; observability_backend = target.target.observability_backend
      ; alert_receiver_type = target.target.alert_receiver_type
      ; alert_receiver_url = target.target.alert_receiver_url
      ; alert_owner = target.target.alert_owner
      ; alert_runbook_url = target.target.alert_runbook_url
      ; outputs
      }
;;

let platform_terraform_vars inputs =
  let add_opt key value vars =
    match value with
    | None -> vars
    | Some value -> (key ^ "=" ^ value) :: vars
  in
  let outputs = inputs.outputs in
  let vars =
    [ "base_domain=" ^ inputs.base_domain
    ; "letsencrypt_email=" ^ inputs.letsencrypt_email
    ; "cloud_provider=aws"
    ; "aws_region=" ^ inputs.region
    ; "install_postgresql=false"
    ; "cert_manager_irsa_role_arn=" ^ outputs.cert_manager_irsa_role_arn
    ; "managed_resource_dashboards="
      ^ Yojson.Safe.to_string outputs.managed_resource_dashboards
    ]
  in
  let vars =
    vars
    |> add_opt "cluster_issuer" inputs.cluster_issuer
    |> add_opt "observability_backend" inputs.observability_backend
    |> add_opt "alert_receiver_type" inputs.alert_receiver_type
    |> add_opt "alert_receiver_url" inputs.alert_receiver_url
    |> add_opt "alert_owner" inputs.alert_owner
    |> add_opt "alert_runbook_url" inputs.alert_runbook_url
    |> add_opt "loki_s3_bucket" outputs.loki_s3_bucket
    |> add_opt "loki_irsa_role_arn" outputs.loki_irsa_role_arn
    |> add_opt "thanos_s3_bucket" outputs.thanos_s3_bucket
    |> add_opt "thanos_irsa_role_arn" outputs.thanos_irsa_role_arn
    |> add_opt "grafana_irsa_role_arn" outputs.grafana_irsa_role_arn
  in
  vars
;;

type plan_phase =
  | Plannable
  | Deferred of string

(* [rbac_established] is a plan-only prerequisite: establishing the provisioner's
   steady-state RBAC requires an apply, and plan must not mutate to unlock its own
   later phases, so a cluster without it defers both platform phases (ADR 0002).
   [crds_established] only matters once RBAC makes the prerequisites plannable. *)
let platform_plan_phases ~cluster_exists ~rbac_established ~crds_established =
  let requires_cloud = "requires cloud substrate to exist" in
  let requires_rbac =
    "requires provisioner platform RBAC established by an earlier apply"
  in
  if not cluster_exists
  then Deferred requires_cloud, Deferred requires_cloud
  else if not rbac_established
  then Deferred requires_rbac, Deferred requires_rbac
  else if not crds_established
  then Plannable, Deferred "requires cert-manager CRDs to be Established"
  else Plannable, Plannable
;;

type authorization =
  | Required
  | Forbidden

let provisioner_authorization_checks =
  [ Required, [ "create"; "deployments.apps"; "-n"; "monitoring" ]
  ; Required, [ "create"; "services"; "-n"; "ingress-nginx" ]
  ; Required, [ "create"; "customresourcedefinitions.apiextensions.k8s.io" ]
  ; Required, [ "create"; "storageclasses.storage.k8s.io" ]
  ; Required, [ "create"; "clusterissuers.cert-manager.io" ]
  ; Required, [ "create"; "namespaces" ]
  ; Forbidden, [ "create"; "deployments.apps"; "-n"; "default" ]
  ; Forbidden, [ "create"; "services"; "-n"; "default" ]
  ; Forbidden, [ "create"; "jobs.batch"; "-n"; "default" ]
  ; Forbidden, [ "create"; "secrets"; "-n"; "default" ]
  ; Forbidden, [ "bind"; "clusterroles.rbac.authorization.k8s.io" ]
  ; Forbidden, [ "escalate"; "clusterroles.rbac.authorization.k8s.io" ]
  ]
;;

let provisioner_authorization_established ~can_i =
  List.for_all
    (fun (expected, args) ->
       match expected with
       | Required -> can_i args
       | Forbidden -> not (can_i args))
    provisioner_authorization_checks
;;

type readiness =
  | Established
  | Unmet of string

(* INFRA-035: a readiness check is data, not a call site. Keeping [argv] in the
   spec and running it in [readiness] below means the invocations CI validates
   against a real kubectl are the same ones that ship. The previous shape inlined
   them where only the offline harness could see them — and that harness's fake
   kubectl accepts any argv, which is how `rollout status … --all`, a flag kubectl
   does not have, reached a real target and made every platform report `Unmet`. *)
type readiness_check =
  { name : string
  ; reason : string
  ; accept : string -> bool
  ; argv : string list
  }

(* [kubectl rollout status] takes one named resource — it has no [--all] — so
   every check written as `rollout status deployment --all` failed with
   `unknown flag: --all` and never reported the platform's state at all. [wait]
   does accept [--all], and the [Available] condition is the Deployment's own
   authoritative statement that its replicas are available. *)
let available_deployments namespace =
  [ "wait"
  ; "--for=condition=Available"
  ; "deployment"
  ; "--all"
  ; "-n"
  ; namespace
  ; "--timeout=5s"
  ]
;;

(* DaemonSets have no condition [kubectl wait] understands, so their convergence
   is read from status: every daemonset in the namespace must have all of its
   desired pods ready. A daemonset desiring zero pods is not "converged", it is
   not running, so the desired count must be positive rather than letting an
   empty schedule pass as success. *)
(* Desired-to-ready per daemonset, so the predicate below can require all of
   them at once through a single [get]. *)
let daemonsets_ready_jsonpath =
  "jsonpath={range .items[*]}{.status.numberReady}/{.status.desiredNumberScheduled}{' \
   '}{end}"
;;

let all_daemonsets_ready output =
  let pairs =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  pairs <> []
  && List.for_all
       (fun pair ->
          match String.split_on_char '/' pair with
          | [ ready; desired ] ->
            (match int_of_string_opt ready, int_of_string_opt desired with
             | Some ready, Some desired -> desired > 0 && ready = desired
             | None, _ | _, None -> false)
          | _ -> false)
       pairs
;;

let readiness_checks ~cluster_issuer ~observability_backend =
  let check ?(accept = fun _ -> true) name reason argv = { name; reason; accept; argv } in
  let common =
    [ check
        "cert-manager CRDs"
        "required cert-manager CRDs are not Established"
        [ "wait"
        ; "--for=condition=Established"
        ; "crd/certificates.cert-manager.io"
        ; "crd/clusterissuers.cert-manager.io"
        ; "--timeout=5s"
        ]
    ; check
        "cert-manager controllers"
        "cert-manager controller, webhook, or cainjector is unavailable"
        (available_deployments "cert-manager")
    ; check
        "ClusterIssuer"
        "selected ClusterIssuer is not Ready"
        [ "wait"
        ; "--for=condition=Ready"
        ; "clusterissuer/" ^ cluster_issuer
        ; "--timeout=5s"
        ]
    ; check
        ~accept:(fun output -> output = "ebs.csi.aws.com true")
        "default StorageClass"
        "gp3 StorageClass is absent, not default, or uses the wrong CSI provisioner"
        [ "get"
        ; "storageclass/gp3"
        ; "-o"
        ; "jsonpath={.provisioner}{' \
           '}{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}"
        ]
    ; check
        "EBS CSI driver"
        "EBS CSI driver is not registered"
        [ "get"; "csidriver/ebs.csi.aws.com" ]
    ; check
        "Redpanda"
        "Redpanda broker-native cluster health is not healthy"
        [ "exec"
        ; "-n"
        ; "redpanda"
        ; "statefulset/redpanda"
        ; "--"
        ; "rpk"
        ; "cluster"
        ; "health"
        ; "--exit-when-healthy"
        ; "--watch=false"
        ]
    ; check
        "ingress-nginx"
        "ingress-nginx controller is unavailable"
        (available_deployments "ingress-nginx")
    ; check
        ~accept:(fun output -> output <> "")
        "ingress endpoint"
        "ingress-nginx LoadBalancer has no assigned endpoint"
        [ "get"
        ; "service/ingress-nginx-controller"
        ; "-n"
        ; "ingress-nginx"
        ; "-o"
        ; "jsonpath={.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}"
        ]
    ; check
        "Argo CD"
        "an Argo CD controller is unavailable"
        (available_deployments "argocd")
    ; check
        "Prometheus"
        "Prometheus native readiness endpoint failed"
        [ "get"
        ; "--raw"
        ; "/api/v1/namespaces/monitoring/services/http:prometheus-server:80/proxy/-/ready"
        ]
    ; check
        ~accept:all_daemonsets_ready
        "monitoring daemonsets"
        "a monitoring daemonset does not have every desired agent ready"
        [ "get"; "daemonset"; "-n"; "monitoring"; "-o"; daemonsets_ready_jsonpath ]
    ]
  in
  let local_observability =
    if observability_backend = "external"
    then []
    else
      [ check
          "Loki"
          "Loki native readiness endpoint failed"
          [ "get"
          ; "--raw"
          ; "/api/v1/namespaces/monitoring/services/http:loki:3100/proxy/ready"
          ]
      ; check
          "Grafana"
          "Grafana native health endpoint failed"
          [ "get"
          ; "--raw"
          ; "/api/v1/namespaces/monitoring/services/http:grafana:80/proxy/api/health"
          ]
      ; check
          "Tempo"
          "Tempo native readiness endpoint failed"
          [ "get"
          ; "--raw"
          ; "/api/v1/namespaces/monitoring/services/http:tempo:3100/proxy/ready"
          ]
      ]
  in
  let durable_observability =
    if observability_backend = "self_hosted_durable"
    then
      [ check
          "Thanos"
          "Thanos query native readiness endpoint failed"
          [ "get"
          ; "--raw"
          ; "/api/v1/namespaces/monitoring/services/http:thanos-query:9090/proxy/-/ready"
          ]
      ]
    else []
  in
  common @ local_observability @ durable_observability
;;

(** Run every readiness check and report the ones that are not established.
    A check is established only when its invocation succeeds *and* its output
    satisfies [accept], so a command that exits zero while saying nothing useful
    does not count as evidence. *)
let readiness ~cluster_issuer ~observability_backend ~run =
  List.map
    (fun check ->
       ( check.name
       , match run check.argv with
         | Some output when check.accept (String.trim output) -> Established
         | _ -> Unmet check.reason ))
    (readiness_checks ~cluster_issuer ~observability_backend)
;;

(** The kubectl invocations the checks above run, exposed so CI can validate them
    against a real kubectl. Nothing calls this in production — it exists because
    the invocations are otherwise only reachable through [readiness], which needs
    a live cluster, so a flag that kubectl does not have could ship unnoticed. *)
let readiness_invocations ~cluster_issuer ~observability_backend =
  List.map
    (fun check -> check.name, check.argv)
    (readiness_checks ~cluster_issuer ~observability_backend)
;;

let readiness_summary checks =
  match
    List.filter_map
      (fun (name, result) ->
         match result with
         | Established -> None
         | Unmet reason -> Some (name ^ ": " ^ reason))
      checks
  with
  | [] -> "Ready"
  | unmet -> "Unmet — " ^ String.concat "; " unmet
;;

(* ── Lifecycle phases: authority and desired-state policy (ADR 0003) ──────────

   HARDEN-002 run 4 (findings 13, 14, 15) showed that the lifecycle needs an
   explicit notion of *which operation Sol is performing*, because that decides
   both the authority it may use and which desired-state policy applies. Two
   individually-correct rules contradicted each other only because no phase said
   which one was in force:

     BUG-039      production-single-region/v1 -> RDS deletion protection = true
     INFRA-023    PrepareDestroy              -> RDS deletion protection = false

   A [phase] is NOT infrastructure truth: Terraform state remains authoritative
   for managed resources and AWS/Kubernetes provide observed reality. It names
   the operation/transition, and therefore the authority and policy, Sol is
   applying right now; it is derived from the command and its verified
   preparation, never persisted as a second state database. *)

type phase =
  | Absent
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying

(* The desired-state policy a phase applies. [Installation] and [Production]
   differ in authority even where their substitution vars coincide today. *)
type phase_policy =
  | Bootstrap
  | Installation
  | Production
  | Destroy

let policy_of_phase = function
  | Absent | Cloud_bootstrap -> Bootstrap
  | Platform_installing | Platform_updating -> Installation
  | Ready -> Production
  | Preparing_destroy | Destroying -> Destroy
;;

(* The forward lifecycle relation: the edges of ADR 0003's diagram. Anything not
   listed is illegal; the operations in cmd_cloud_tf.ml perform only listed
   transitions, and the tests assert the illegal ones are rejected.

   This is deliberately NOT the whole story about how a phase can be entered. It
   describes *progressive establishment* -- each edge moves the target further
   along the diagram, so reversing one is illegal (invariant 5). Teardown is a
   different class of move and is described separately by [destruction_available];
   keeping the two apart is what lets this relation keep saying exactly what the
   diagram says. *)
let transition_allowed ~from ~to_ =
  match from, to_ with
  | Absent, Cloud_bootstrap -> true
  | Cloud_bootstrap, Platform_installing -> true
  | Platform_installing, Ready -> true
  | Ready, Platform_updating -> true
  | Platform_updating, Ready -> true
  | Ready, Preparing_destroy -> true
  | Preparing_destroy, Destroying -> true
  | Destroying, Absent -> true
  | _ -> false
;;

(* The abort edge (ADR 0003 invariant 6).

   Destruction is not a forward lifecycle transition, so it is not in the relation
   above -- which is why `Platform_installing -> Preparing_destroy` is correctly
   *rejected* there. It is nonetheless available from every phase that can hold
   infrastructure, including a half-built one, because lifecycle enforcement must
   never strand infrastructure: a run that fails midway (a partial install, an
   interrupted privileged update, a destroy that died before finishing) has to
   remain destructible through Sol's public lifecycle, or the only way out is
   manual console surgery on live cloud resources.

   [Absent] is the post-destroy state and has nothing to tear down. *)
let destruction_available = function
  | Absent -> false
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying -> true
;;

(* The phase a destroy operation proceeds in. Total by construction: destroying an
   already-absent target yields [Absent], the post-destroy state itself, which is
   why destroy is idempotent rather than an error.

   Note what this does *not* need: the answer is [Preparing_destroy] for every
   phase except [Absent], so a destroy has to decide only Absent-ness -- which is
   observable from the substrate Sol is about to tear down. It deliberately does
   not probe the platform: a probe that can fail must never be able to block
   teardown, and would strand exactly the half-built target this exists to
   protect. *)
let enter_destruction ~from =
  if destruction_available from then Preparing_destroy else Absent
;;

(* Ready-state invariants apply only in [Ready]. Once [Preparing_destroy] has
   succeeded no later reconciliation may re-apply them (finding 15) -- BUG-039
   stays exactly correct throughout [Ready] and is deliberately left behind when
   the target leaves it. *)
let ready_policy_applies phase = policy_of_phase phase = Production

(* The desired-state overrides a phase imposes. Callers append these AFTER their
   own variables so the phase policy wins. [Destroy] deliberately contradicts the
   Production invariant for RDS deletion protection. *)
let policy_vars ~phase ~destroy_snapshot_id =
  match policy_of_phase phase with
  | Bootstrap | Installation | Production -> []
  | Destroy ->
    [ "rds_deletion_protection", "false"
    ; "rds_skip_final_snapshot", "false"
    ; "rds_final_snapshot_identifier", destroy_snapshot_id
    ]
;;

(* The operator-facing name of a phase (ADR 0003's own spelling). Kept here so a
   report, an error message and a test label cannot drift from the model. *)
let phase_to_string = function
  | Absent -> "Absent"
  | Cloud_bootstrap -> "CloudBootstrap"
  | Platform_installing -> "PlatformInstalling"
  | Ready -> "Ready"
  | Platform_updating -> "PlatformUpdating"
  | Preparing_destroy -> "PreparingDestroy"
  | Destroying -> "Destroying"
;;

(* The phase a target is actually in, recomputed from observation on every run --
   the phase is never persisted and is never infrastructure truth (ADR 0003).
   [cloud_exists] is what Terraform reports for the substrate. [platform_installed]
   is a cheap, privilege-independent observation that an *earlier* run completed
   the platform install (the cert-manager CRDs are cluster objects, so unlike a
   `kubectl auth can-i` probe they are unaffected by the bootstrap-admin
   escalation the current run performs itself). An installed-but-not-fully-Ready
   target observes as [Ready] here because the operation it admits is the same
   privileged re-establishment; the transition is still verified to [Ready] before
   the run may leave it. *)
let observed_phase ~cloud_exists ~platform_installed =
  if not cloud_exists
  then Absent
  else if platform_installed
  then Ready
  else Platform_installing
;;

(* The only way an operation may move between phases. A call site cannot express
   an edge the relation does not admit (ADR 0003 invariant 5), so
   `Preparing_destroy -> Ready` and `Ready -> Platform_installing` are refused
   here rather than by an operator or a call site remembering to check. Remaining
   in the same phase is not a transition and is deliberately not routed through
   this. *)
let enter ~from ~to_ =
  if transition_allowed ~from ~to_
  then Ok to_
  else
    Error
      (Printf.sprintf
         "illegal lifecycle transition %s -> %s"
         (phase_to_string from)
         (phase_to_string to_))
;;
