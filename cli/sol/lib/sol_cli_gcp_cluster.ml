(* REFAC-096: the GCP cluster behind [Sol_cli_cluster.t].

   The GCP cloud root's outputs, their parsing, and everything that reaches the
   GKE cluster with them live here, private to the provider: the ephemeral
   kubeconfig from `gcloud container clusters get-credentials`, the host
   toolchain it needs, and the substrate readiness check. GCP's bootstrap window
   lives in the platform root and is closed by applying it, so there is no
   Sol-side window to observe. Moved verbatim from `cmd_cloud_tf.ml` and
   `Sol_cli_cloud_lifecycle`. *)

let ( let* ) = Result.bind

(* GCP's cloud-root contract: its own type, deliberately, rather than a relabelled
   [aws_outputs]. The two providers publish different facts, not the same facts
   under different names -- a GCP root names the project and region because every
   GCP API is addressed through them *and* the cluster credential is derived from
   them, and names no role ARN because a caller there impersonates a service
   account through short-lived credentials. One record carrying both shapes would
   make every field optional and leave every reader responsible for knowing which
   fields its provider actually fills in. *)
type gcp_outputs =
  { cluster_name : string
  ; project_id : string
  ; region : string
  ; artifact_registry : string
  ; loki_gcs_bucket : string option
  ; loki_workload_identity_sa_email : string option
  ; thanos_gcs_bucket : string option
  ; thanos_workload_identity_sa_email : string option
  ; provisioner_service_account : string
  }

let gcp_outputs_of_json text =
  try
    let _, string, optional_string =
      Sol_cli_cluster.outputs_reader ~provider:"GCP" text
    in
    let ( let* ) = Result.bind in
    let* cluster_name = string "cluster_name" in
    let* project_id = string "project_id" in
    let* region = string "region" in
    let* artifact_registry = string "artifact_registry" in
    let* loki_gcs_bucket = optional_string "loki_gcs_bucket" in
    let* loki_workload_identity_sa_email =
      optional_string "loki_workload_identity_sa_email"
    in
    let* thanos_gcs_bucket = optional_string "thanos_gcs_bucket" in
    let* thanos_workload_identity_sa_email =
      optional_string "thanos_workload_identity_sa_email"
    in
    (* Required, not optional: without it the platform would be installed as
       whatever identity happened to call Sol, which is the thing Attempt 1 did
       and the review named as not being an authority model. *)
    let* provisioner_service_account = string "provisioner_service_account" in
    Ok
      { cluster_name
      ; project_id
      ; region
      ; artifact_registry
      ; loki_gcs_bucket
      ; loki_workload_identity_sa_email
      ; thanos_gcs_bucket
      ; thanos_workload_identity_sa_email
      ; provisioner_service_account
      }
  with
  | Yojson.Json_error message -> Error ("invalid GCP Terraform output JSON: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    Error ("invalid GCP Terraform outputs: " ^ message)
;;

(* The GCP counterpart of [provisioner_kubeconfig], and the same semantic: an
   ephemeral kubeconfig for *this target's* cluster, in a temp file, exported
   under every name the platform providers read (finding 12), never the
   operator's ambient one.

   What differs is how a credential is obtained. AWS assumes a role through
   `aws eks update-kubeconfig --role-arn`; GCP asks the cluster for credentials
   with the caller's Application Default Credentials. Sol does not yet narrow
   that caller to a provisioner service account of its own on GCP -- there is no
   GCP equivalent of the AWS root's provisioner role -- so this is the target's
   Owner identity in the privileged install window, which is a recorded gap and
   not something this function should paper over. *)
(* Attempt 3's first meaningful failure, moved to where it belongs.

   The platform applies authenticate to GKE through the kubeconfig gcloud writes,
   and that kubeconfig names `gke-gcloud-auth-plugin` as its client-go exec
   credential plugin. Without it, every Kubernetes call dies with
   `exec: executable gke-gcloud-auth-plugin not found` -- *inside* the platform
   apply, which is to say after GKE and Cloud SQL have been provisioned and paid
   for, and after Sol has spent its way to the interesting part.

   That is a host prerequisite in the same class as terraform itself, so it is
   checked before the first platform call rather than discovered by one. Failing
   here costs nothing; failing there costs an apply. *)
let gcp_platform_toolchain_result () : (unit, string) result =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "gke-gcloud-auth-plugin"; "--version" ])
  with
  | Ok result when result.Sol_cli_process.exit_code = 0 -> Ok ()
  | _ ->
    Error
      "the platform cannot reach a GKE cluster without `gke-gcloud-auth-plugin`, which \
       is not on PATH: the kubeconfig gcloud writes names it as its credential plugin, \
       so every Kubernetes call would fail with \"executable gke-gcloud-auth-plugin not \
       found\". Install it (`gcloud components install gke-gcloud-auth-plugin`) and \
       re-run. Nothing has been changed."
;;

let gcp_provisioner_kubeconfig_result
      ~region
      outputs
      (f : env:(string * string) list -> ('a, string) result)
  : ('a, string) result
  =
  let* () = gcp_platform_toolchain_result () in
  let path = Filename.temp_file "sol-platform-provisioner-" ".kubeconfig" in
  let cleanup () =
    try Sys.remove path with
    | Sys_error _ -> ()
  in
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
    let env = Sol_cli_cluster.provisioner_kube_env path in
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           ~env
           [ "gcloud"
           ; "container"
           ; "clusters"
           ; "get-credentials"
           ; outputs.cluster_name
           ; "--region"
           ; region
           ; "--project"
           ; outputs.project_id
             (* Impersonation is the point: Sol acts as the target's named
              provisioner, through short-lived tokens, rather than as whoever
              happened to run the command. *)
           ; "--impersonate-service-account"
           ; outputs.provisioner_service_account
             (* No `--kubeconfig`. Attempt 2's first live failure was
                "unrecognized arguments: --kubeconfig": the flag does not exist on
                this subcommand. gcloud writes to the kubeconfig named by
                `$KUBECONFIG`, which [provisioner_kube_env] has already exported for
                this child, and that is the interface it actually has.

                The offline stub accepted the flag because it was written from this
                implementation, which is the limitation worth remembering: a stub
                cannot falsify the interface it was modelled on.
                `check_gcloud_interface.sh` now validates the argv against gcloud's
                own help output instead. *)
           ; "--quiet"
           ])
    with
    | Ok result when result.exit_code = 0 -> f ~env
    | Ok result ->
      (* Attempt 2 also showed why this failed without saying so. The message named
         the step and nothing else, so the reason -- a missing impersonation grant
         versus a wrong flag -- had to be reconstructed by hand. *)
      Error
        (Printf.sprintf
           "could not establish ephemeral cluster access as %s: gcloud exited %d%s"
           outputs.provisioner_service_account
           result.Sol_cli_process.exit_code
           (let detail = String.trim result.Sol_cli_process.stderr in
            if detail = "" then "" else ":\n" ^ detail))
    | Error error ->
      Error
        (Printf.sprintf
           "could not run gcloud to establish cluster access: %s"
           (Sol_cli_process.error_to_string error)))
;;

(* What "the cloud substrate is Ready" means on GCP: the GKE control plane is
   RUNNING and the Cloud SQL instance is RUNNABLE. The AWS check also asserts the
   EBS CSI addon is ACTIVE because Sol creates it; on GKE the block-storage
   provisioner is part of the platform the provider manages, and the storage
   contract is asserted at the Kubernetes layer instead -- the provider's
   StorageClass is the sole default and is backed by its CSI driver, which is the
   check that actually covers what a workload binds to. *)
let gcp_cloud_ready outputs =
  let project = outputs.project_id in
  let region = outputs.region in
  let cluster = outputs.cluster_name in
  let status argv = Sol_cli_cluster.process_output ([ "gcloud" ] @ argv) in
  match
    ( status
        [ "container"
        ; "clusters"
        ; "describe"
        ; cluster
        ; "--region"
        ; region
        ; "--project"
        ; project
        ; "--format"
        ; "value(status)"
        ]
    , status
        [ "sql"
        ; "instances"
        ; "describe"
        ; cluster ^ "-postgres"
        ; "--project"
        ; project
        ; "--format"
        ; "value(state)"
        ] )
  with
  | Some cluster_status, Some sql_state
    when String.trim cluster_status = "RUNNING" && String.trim sql_state = "RUNNABLE" ->
    true
  | _ -> false
;;

(* The provider's share of the platform definition's variables. *)
let platform_vars
      outputs
      (context : Sol_cli_cluster.platform_vars_context)
      ~cluster_issuer
      ~region:_
  =
  (* Refused rather than half-wired: the definition's ClusterIssuers are still
     the Route 53 DNS-01 solver, so a GCP target that expects TLS would get a
     platform that looks wired for it and cannot issue. `cluster_issuer` is
     optional, so this is a refusal only when a target actually asks for the
     capability -- and a target that does not ask for it gets a platform with no
     issuer rather than an issuer that cannot work. *)
  match cluster_issuer, context with
  | Some _, Install ->
    Error
      "this GCP target declares cluster_issuer, but Sol cannot yet wire a certificate \
       issuer on GCP: the shared platform definition's ClusterIssuers use the Route 53 \
       DNS-01 solver and there is no qualified Cloud DNS solver or scoped Workload \
       Identity for cert-manager yet. Remove cluster_issuer from the target to provision \
       the platform without public TLS, or qualify the GCP issuer path first"
  | Some _, Destruction | None, _ ->
    Ok
      { Sol_cli_cluster.fixed =
          [ "cloud_provider=gcp"; "storage_class_name=standard-rwo" ]
      ; optional =
          [ "loki_gcs_bucket", outputs.loki_gcs_bucket
          ; "loki_workload_identity_sa_email", outputs.loki_workload_identity_sa_email
          ; "thanos_gcs_bucket", outputs.thanos_gcs_bucket
          ; "thanos_workload_identity_sa_email", outputs.thanos_workload_identity_sa_email
            (* The identity that holds the platform's authorities on GCP. It is
             provider-shaped data for the same reason the buckets are: the
             definition binds *this* identity to the same ClusterRoles the AWS
             provisioner's group receives, so the authority model is shared and
             the identity is not. *)
          ; "gcp_provisioner_service_account", Some outputs.provisioner_service_account
          ]
      }
;;

let label = "GCP"
let of_outputs_json = gcp_outputs_of_json

let cluster ~region outputs : Sol_cli_cluster.t =
  { name = outputs.cluster_name
  ; (* A GCP caller impersonates a service account; there is no role-shaped
       identity to compare against the target's declaration. *)
    check_identity = (fun ~cluster_access_role_arn:_ -> Ok ())
  ; platform_vars = platform_vars outputs
  ; with_access = (fun f -> gcp_provisioner_kubeconfig_result ~region outputs f)
  ; ready = (fun () -> gcp_cloud_ready outputs)
  ; bootstrap_window = Sol_cli_cluster.Closed_by_platform_root
  }
;;
