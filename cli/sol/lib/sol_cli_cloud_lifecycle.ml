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

(* Readiness: is the platform converged? ------------------------------------
   [Ready] is what licenses `PlatformInstalling -> Ready` (ADR 0003), so it
   asserts that the platform reached its defined operational state according to
   authoritative Kubernetes state. Two things it deliberately does NOT do, both
   learned from a real target:

   * It does not probe the platform across the network. The five checks that read
     service endpoints through the API server's `/proxy/` path needed a route this
     platform never creates — the EKS module admits the control plane to nodes
     only on the admission-webhook ports — so a fully converged platform reported
     `Unmet`. Whether a capability *works* is HARDEN's question, and HARDEN
     answers it with behaviour (a known log reaches Loki and can be queried), not
     with a route.
   * It does not require an external ACME round trip. A ClusterIssuer's only
     condition is `Ready`, and for an ACME issuer cert-manager sets it only after
     registering with the external CA, so an unreachable Let's Encrypt would make
     a converged platform "not ready". Real issuance is qualified in HARDEN.

   What is left is convergence: Kubernetes' own statement about its own objects.
   Workloads are read per kind because kinds differ in what they declare — a
   DaemonSet's desired count is derived from the node set, so zero means nothing
   matched, while a StatefulSet's replicas are declared by its owner. *)
type readiness_check =
  { name : string
  ; reason : string
  ; accept : string -> bool
  ; argv : string list
  }

let check ?(accept = fun _ -> true) name reason argv = { name; reason; accept; argv }

(* Deployments state their own availability through their own condition. *)
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

(* DaemonSets and StatefulSets have no condition [kubectl wait] understands, so
   convergence comes from status, as ready/desired pairs. *)
let converged_workload ~kind ~namespace ~ready_field ~desired_field =
  [ "get"
  ; kind
  ; "-n"
  ; namespace
  ; "-o"
  ; Printf.sprintf
      "jsonpath={range .items[*]}{.%s}/{.%s}{' '}{end}"
      ready_field
      desired_field
  ]
;;

let converged_daemonsets namespace =
  converged_workload
    ~kind:"daemonset"
    ~namespace
    ~ready_field:"status.numberReady"
    ~desired_field:"status.desiredNumberScheduled"
;;

let converged_statefulsets namespace =
  converged_workload
    ~kind:"statefulset"
    ~namespace
    ~ready_field:"status.readyReplicas"
    ~desired_field:"status.replicas"
;;

let bound_pvcs namespace =
  [ "get"
  ; "pvc"
  ; "-n"
  ; namespace
  ; "-o"
  ; "jsonpath={range .items[*]}{.status.phase}{' '}{end}"
  ]
;;

let ready_nodes =
  [ "get"
  ; "nodes"
  ; "-o"
  ; "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{' \
     '}{end}"
  ]
;;

(* Every workload reports as many ready replicas as it declares. An empty result
   is never "converged": it means there was nothing to look at, so a query that
   matched nothing would otherwise pass silently. [require_desired] additionally
   rejects a desired count of zero — right for DaemonSets, where zero means the
   node set matched nothing, and wrong for StatefulSets, where a declared zero is
   its owner's choice. *)
let replicas_converged ?(require_desired = true) output =
  let pairs =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  pairs <> []
  && List.for_all
       (fun pair ->
          match String.split_on_char '/' pair with
          | [ ready; desired ] ->
            (match int_of_string_opt ready, int_of_string_opt desired with
             | Some ready, Some desired ->
               ready = desired && (desired > 0 || not require_desired)
             | None, _ | _, None -> false)
          | _ -> false)
       pairs
;;

let daemonsets_converged output = replicas_converged output
let statefulsets_converged output = replicas_converged ~require_desired:false output

(* Every volume is Bound, and there is at least one to look at. *)
let all_pvcs_bound output =
  let phases =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  phases <> [] && List.for_all (fun phase -> phase = "Bound") phases
;;

let all_nodes_ready output =
  let states =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  states <> [] && List.for_all (fun state -> state = "True") states
;;

(* No arguments: the checks do not depend on the observability backend or on the
   issuer. Both were backend-shaped distinctions inside a gate whose only job is
   to state "the platform converged", and the namespace-wide workload checks hold
   for whatever a backend installed. *)
let readiness_checks () =
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
  ; check ~accept:all_nodes_ready "nodes" "a cluster node is not Ready" ready_nodes
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
  ; (* Monitoring is checked namespace-wide: the assertion is "everything
       installed here has converged", which holds for whatever the configured
       observability backend installs and needs no per-chart list to drift. *)
    check
      "monitoring deployments"
      "a monitoring deployment is not available"
      (available_deployments "monitoring")
  ; check
      ~accept:statefulsets_converged
      "monitoring statefulsets"
      "a monitoring statefulset does not have every declared replica ready"
      (converged_statefulsets "monitoring")
  ; check
      ~accept:daemonsets_converged
      "monitoring daemonsets"
      "a monitoring daemonset does not have every scheduled pod ready"
      (converged_daemonsets "monitoring")
  ; check
      ~accept:all_pvcs_bound
      "monitoring PVCs"
      "a monitoring PersistentVolumeClaim is not Bound"
      (bound_pvcs "monitoring")
  ; (* The one behavioural check kept in [Ready]. Redpanda is the platform's own
       broker, so this is the platform's own health API rather than a third
       party's, it needs no route beyond the API server -> kubelet path that
       `kubectl exec` already uses, and "the brokers agree they are healthy" is
       what makes the data plane operable rather than merely scheduled. *)
    check
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
      ~accept:statefulsets_converged
      "Redpanda statefulset"
      "the Redpanda statefulset does not have every declared replica ready"
      (converged_statefulsets "redpanda")
  ; check
      ~accept:all_pvcs_bound
      "Redpanda PVCs"
      "a Redpanda PersistentVolumeClaim is not Bound"
      (bound_pvcs "redpanda")
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
  ]
;;

(* Run every readiness check and report the ones that are not established. A check
   is established only when its invocation succeeds *and* its output satisfies
   [accept]: a command that exits zero while saying nothing useful is not
   evidence. *)
let readiness ~run =
  List.map
    (fun check ->
       ( check.name
       , match run check.argv with
         | Some output when check.accept (String.trim output) -> Established
         | _ -> Unmet check.reason ))
    (readiness_checks ())
;;

(* The kubectl invocations the checks above run, exposed so CI can validate them
   against a real kubectl. Nothing calls this in production — it exists because
   the invocations are otherwise only reachable through [readiness], which needs
   a live cluster, so an argv kubectl rejects could ship unnoticed. *)
let readiness_invocations () =
  List.map (fun check -> check.name, check.argv) (readiness_checks ())
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
