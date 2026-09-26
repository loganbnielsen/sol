(* REFAC-097: how a GCP target honours `destroy_retention`, and the residue of a
   GCP destroy that Terraform does not own.

   GCP cannot retain anything yet -- Cloud SQL deletes its backups with the
   instance -- so a target that asks to keep a final snapshot is refused with the
   gap named (DEC-033), and a target that keeps nothing has its deletion guards
   lowered. Residue is the service-networking peering GCP refuses to delete while
   a producer is registered (INFRA-047). Moved verbatim from `cmd_cloud_tf.ml` and
   `Sol_cli_destroy_verification`. *)

open Sol_cli_destroy_verification
open Sol_cli_destruction
open Sol_cli_terraform_steps

let ( let* ) = Result.bind

(* The name that follows a literal marker, lowercased text assumed. Used to read
   the *subject* out of a gcloud message. *)
let names_after ~marker text =
  let marker_length = String.length marker in
  let text_length = String.length text in
  let is_name_char c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
  in
  let rec scan i acc =
    if i + marker_length > text_length
    then acc
    else if String.sub text i marker_length = marker
    then (
      let start = i + marker_length in
      let rec take j =
        if j < text_length && is_name_char text.[j] then take (j + 1) else j
      in
      let stop = take start in
      let name = String.sub text start (stop - start) in
      scan (max (i + 1) stop) (if name = "" then acc else name :: acc))
    else scan (i + 1) acc
  in
  List.rev (scan 0 [])
;;

(* The project(s) a gcloud message names. Both shapes are real: the resource path
   (`projects/<p>/locations/...`) and the quoted subject (`The project '<p>' was
   not found`). *)
let gcp_mentioned_projects stderr =
  let text = String.lowercase_ascii stderr in
  names_after ~marker:"projects/" text @ names_after ~marker:"project '" text
;;

(* Finding C, closed. GCP answers 404 both for "the object is gone" and for "that
   project is not visible to you", so a not-found is evidence about the object we
   asked for *only when the answer's subject matches*: if the message names a
   project that is not the one this identity was captured in, the answer is about
   something else, and reading it as absence is exactly how a wrong lookup becomes
   a false postcondition. With no captured project to compare against there is
   nothing to contradict, so the wording stands.

   The wording list stays because gcloud publishes no structured result: Attempt 4
   found a 404 the old check could not recognise, and a check that cannot recognise
   absence makes Absent unreachable. *)
let gcp_absence_message ?project stderr =
  let text = String.lowercase_ascii stderr in
  let absent_wording =
    List.exists
      (fun needle -> Sol_cli_string.contains ~needle text)
      [ "code=404"; "httperror 404"; "not_found"; "not found"; "does not exist" ]
  in
  let subject_matches =
    match project with
    | None -> true
    | Some project ->
      let project = String.lowercase_ascii project in
      List.for_all (fun mentioned -> mentioned = project) (gcp_mentioned_projects stderr)
  in
  absent_wording && subject_matches
;;

let gcp_peering_probe ~project ~network =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "gcloud"
         ; "services"
         ; "vpc-peerings"
         ; "list"
         ; "--network=" ^ network
         ; "--service=servicenetworking.googleapis.com"
         ; "--project"
         ; project
         ; "--format=value(peering)"
         ])
  with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    let peerings =
      String.split_on_char '\n' result.Sol_cli_process.stdout
      |> List.map String.trim
      |> List.filter (fun peering -> peering <> "" && peering <> "---")
    in
    if peerings = []
    then Probe_gone
    else
      Probe_found
        (Printf.sprintf
           "the service-networking peering survived the destroy: %s"
           (String.concat ", " peerings))
  | Ok result when gcp_absence_message ~project result.Sol_cli_process.stderr ->
    Probe_gone
  | Ok result ->
    Probe_indeterminate
      (Printf.sprintf
         "the service-networking peering could not be checked: %s"
         (String.trim result.Sol_cli_process.stderr))
  | Error _ ->
    Probe_indeterminate
      "the service-networking peering could not be checked: gcloud is unavailable"
;;

(* GCP's peering check asks about the network Terraform recorded, not one rebuilt
   from the cluster name: a network that does not exist has no peerings, so asking
   about the wrong one would answer "gone" for the wrong reason. The project comes
   from the root's own outputs; without them the check is a reported gap, never a
   guess. *)
let gcp_orphan_sweep ~pre_destroy ~(target_cfg : Sol_cli_config.target) =
  (* The project the root was applied in: the target's own `gcp.project_id`, which
     is the variable the root receives (its `project_id` output only echoes it). *)
  let project =
    List.assoc_opt "gcp" target_cfg.provider_fields
    |> Option.map (List.assoc_opt "project_id")
    |> Option.join
    |> Option.map String.trim
    |> Option.to_list
    |> List.find_opt (fun project -> project <> "")
  in
  match state_name pre_destroy "google_compute_network", project with
  | Some network, Some project -> orphan_sweep [ gcp_peering_probe ~project ~network ]
  | None, _ ->
    orphan_sweep
      ~gaps:
        [ "the GCP residue check could not name the target's VPC from Terraform state, \
           so the service-networking peering check was not run"
        ]
      []
  | Some _, None ->
    orphan_sweep
      ~gaps:
        [ "the GCP residue check could not establish the target's project (the target \
           declares no gcp.project_id), so the service-networking peering check was not \
           run"
        ]
      []
;;

let gcp_prepare_destroy_result ~guarded run_log infra_dir var_files vars state
  : unit Sol_cli_cloud_lifecycle.preparation_outcome
  =
  let open Sol_cli_cloud_lifecycle in
  let open Sol_cli_cloud_destroy in
  (* Guard lowering is best-effort preparation (FND-0030): a failure here must not
     strand a half-built target, so it permits destruction to continue and stays
     visible in the outcome. The state-side of the decision is the same inventory
     the sequence classified. *)
  let failed reason = Preparation_failed { reason; policy = Continue_to_destroy } in
  let report_unrepresented unrepresented =
    (* FND-0030's actual leak, said out loud. Terraform destroys what its state holds, so a
       resource this target declares and its state does not know about survives the destroy
       -- and stays billable. Skipping it avoids the 409 of Attempt 6; without this report,
       that turns a loud failure into a quiet success. Adopting it is the only way to reach
       it, and that is a separate capability. *)
    match unrepresented with
    | [] -> ()
    | addresses ->
      Printf.printf
        "  WARNING: %d resource(s) this target declares are ABSENT from its state and \
         will therefore NOT be destroyed: %s\n\
        \  They may still exist in the provider and remain billable (FND-0030).\n\
         %!"
        (List.length addresses)
        (String.concat ", " addresses)
  in
  match substrate_presence state with
  | Substrate_unknown ->
    (* The state could not be read, so nothing can be claimed about what is
       represented. That is a preparation that could not run -- deliberately
       distinct from "there was nothing to prepare" -- and it permits destruction
       to continue; UNKNOWN is never read as absence. *)
    Printf.printf "  prepare: could not read this target's state; preparing nothing.\n%!";
    failed
      "the target's Terraform state could not be read, so no deletion guard could be \
       lowered"
  | Substrate_present | Substrate_absent ->
    let represented = addresses state in
    let desired = guarded in
    report_unrepresented
      (Sol_cli_cloud_lifecycle.preparations_unrepresented ~state:represented ~desired);
    (match Sol_cli_cloud_lifecycle.preparations_eligible ~state:represented ~desired with
     | [] ->
       Printf.printf
         "  prepare: no guarded resource in this target's state, nothing is targeted.\n%!";
       Nothing_to_prepare
     | first :: rest ->
       Printf.printf
         "  prepare: disabling the deletion guards on %s...\n%!"
         (String.concat ", " (first :: rest));
       (match
          apply_asserted
            ~run_log
            ~phase_name:"gcp-destroy-prepare"
            ~policy:(guard_preparation_policy ~addresses:(first :: rest))
            ~scope:(Sol_cli_terraform.targets first rest)
            ~chdir:infra_dir
            ~var_files
            ~vars:
              (vars @ [ "sql_deletion_protection=false"; "gke_deletion_protection=false" ])
            ()
        with
        | Error message -> failed message
        | Ok () -> Prepared ()))
;;

(* Only reached once an apply has actually targeted the guards, so there is no
   "nothing was prepared" case to represent -- which is what resolves the old
   `~prepared:false` ambiguity. *)
let verify_gcp_destroy_preparation_result infra_dir =
  let* state = read_cloud_state infra_dir in
  let open Sol_cli_cloud_destroy in
  let guard address =
    Option.bind (find_address state address) (fun resource ->
      resource.deletion_protection)
  in
  if
    find_address state "google_sql_database_instance.postgres" = None
    && find_address state "google_container_cluster.main" = None
  then Error "GCP destroy preparation ran but no guarded resource is in state"
  else
    let* () =
      match guard "google_sql_database_instance.postgres" with
      | Some true ->
        Error "Cloud SQL deletion protection is still enabled after preparation"
      | Some false | None -> Ok ()
    in
    let* () =
      match guard "google_container_cluster.main" with
      | Some true -> Error "GKE deletion protection is still enabled after preparation"
      | Some false | None -> Ok ()
    in
    Printf.printf
      "  verify preparation: Cloud SQL and GKE deletion protection disabled.\n%!";
    Ok ()
;;

(* Retention on GCP: nothing can be kept, so there is nothing to observe beyond
   the verified absence of the instance -- and that is said rather than dressed up. *)
let observe_retention ~retention =
  match retention with
  | Sol_cli_cloud_lifecycle.Retain_nothing ->
    Retention_not_required
      "none declared, and there is no GCP snapshot surface to observe -- Cloud SQL \
       deletes its backups together with the instance (no final backup is requested), \
       and the observability buckets were created with soft delete off (retention 0, \
       INFRA-077), so the verified absence of the instance is the whole guarantee \
       (destroy_retention = none)"
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
    (* Unreachable: a GCP target whose retention is final-snapshot is blocked in
        preparation, so destruction never runs. Reaching here means the block was
        not applied, which must not read as a met guarantee. *)
    Retention_unknown
      "this destroy reached verification with destroy_retention = final-snapshot on GCP, \
       which cannot retain anything: the block was not applied, so no retention \
       guarantee can be observed"
;;

let prepare { run_log; infra_dir; var_files; vars; _ } ~retention ~cluster_name:_ ~state =
  (* DEC-033: a target that destroys must say what it keeps, and GCP cannot keep
     anything today -- Cloud SQL deletes its backups with the instance, so there is
     no final-artifact equivalent of the RDS snapshot. Rather than let the
     [Retain_final_snapshot] *default* quietly become "destroy the recovery data
     anyway", which is the laundering DEC-033 exists to prevent, Sol refuses and
     names the gap. A disposable target opts in with `destroy_retention: none`,
     which is a statement rather than a default.

     Step 4: that refusal is a declared destruction-time guarantee, so it carries
     [Block_destroy] and the target is left standing -- with the guarantee named --
     rather than being destroyed while discarding the recovery data it asked to
     keep. *)
  match retention with
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
    Sol_cli_cloud_lifecycle.Preparation_failed
      { reason =
          "this GCP target's destroy_retention is final-snapshot (the default), but Sol \
           cannot retain anything on GCP yet: Cloud SQL deletes its backups together \
           with the instance, so there is no final-artifact equivalent of the RDS \
           snapshot and the recovery data would be discarded without saying so. Declare \
           `destroy_retention: none` on a disposable target, or export the database \
           first -- Sol will not decide this for you"
      ; policy = Sol_cli_cloud_lifecycle.Block_destroy
      }
  | Sol_cli_cloud_lifecycle.Retain_nothing ->
    (* The verification is part of the preparation here too: an applied transition
        that did not actually lower the guards is not a preparation. Guard lowering
        is best-effort, so this failure permits destruction to continue. *)
    (match
       gcp_prepare_destroy_result
         ~guarded:Sol_cli_provider_capabilities.gcp.guarded_addresses
         run_log
         infra_dir
         var_files
         vars
         state
     with
     | Sol_cli_cloud_lifecycle.Prepared () ->
       (match verify_gcp_destroy_preparation_result infra_dir with
        | Ok () ->
          Sol_cli_cloud_lifecycle.Prepared
            (Sol_cli_cloud_destroy.Prepared { retained = None })
        | Error reason ->
          Sol_cli_cloud_lifecycle.Preparation_failed
            { reason; policy = Sol_cli_cloud_lifecycle.Continue_to_destroy })
     | Sol_cli_cloud_lifecycle.Nothing_to_prepare ->
       Sol_cli_cloud_lifecycle.Nothing_to_prepare
     | Sol_cli_cloud_lifecycle.Preparation_failed failure ->
       Sol_cli_cloud_lifecycle.Preparation_failed failure)
;;

let destruction ctx : Sol_cli_destruction.t =
  { prepare = prepare ctx
  ; retention =
      (fun ~retention ~pre_destroy:_ ~preparation:_ -> observe_retention ~retention)
  ; residue =
      (fun ~pre_destroy ~cluster:_ ->
        gcp_orphan_sweep ~pre_destroy ~target_cfg:ctx.target)
  ; before_substrate_destroy = ignore
  }
;;
