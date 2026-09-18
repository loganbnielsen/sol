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
    let value name = json |> member name |> member "value" in
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

let readiness ~cluster_issuer ~observability_backend ~run =
  let check ?(accept = fun _ -> true) name reason argv =
    ( name
    , match run argv with
      | Some output when accept (String.trim output) -> Established
      | _ -> Unmet reason )
  in
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
        [ "rollout"
        ; "status"
        ; "deployment"
        ; "--all"
        ; "-n"
        ; "cert-manager"
        ; "--timeout=5s"
        ]
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
        [ "rollout"
        ; "status"
        ; "deployment"
        ; "--all"
        ; "-n"
        ; "ingress-nginx"
        ; "--timeout=5s"
        ]
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
        [ "rollout"; "status"; "deployment"; "--all"; "-n"; "argocd"; "--timeout=5s" ]
    ; check
        "Prometheus"
        "Prometheus native readiness endpoint failed"
        [ "get"
        ; "--raw"
        ; "/api/v1/namespaces/monitoring/services/http:prometheus-server:80/proxy/-/ready"
        ]
    ; check
        "Alloy"
        "Alloy does not have every desired agent ready"
        [ "rollout"; "status"; "daemonset"; "--all"; "-n"; "monitoring"; "--timeout=5s" ]
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
