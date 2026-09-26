(* REFAC-097: how an AWS target honours `destroy_retention`, and the residue of an
   AWS destroy that Terraform does not own.

   Retention on AWS is the RDS final snapshot: preparation lowers the instance's
   deletion protection and settles a unique snapshot identity, and after the
   destroy the snapshot must exist and be available -- or, for a target that keeps
   nothing, no snapshot of its instance may remain. Residue is what the in-cluster
   cloud controller and PVCs create outside Terraform: tagged load balancers and
   EBS volumes. Moved verbatim from `cmd_cloud_tf.ml` and
   `Sol_cli_destroy_verification`; the lifecycle sees only [destruction]. *)

open Sol_cli_destroy_verification
open Sol_cli_destruction
open Sol_cli_terraform_steps

let ( let* ) = Result.bind

(* `An error occurred (Code) when calling the Operation operation: ...`. The code
   is what a caller is allowed to branch on; the prose around it is not. *)
let aws_error_code stderr =
  let open_ = String.index_opt stderr '(' in
  match open_ with
  | None -> None
  | Some open_ ->
    let close = String.index_from_opt stderr (open_ + 1) ')' in
    (match close with
     | Some close when close > open_ + 1 ->
       Some (String.sub stderr (open_ + 1) (close - open_ - 1))
     | _ -> None)
;;

(* [Pending] is the provider saying "not yet": the snapshot exists and has not
   reached the state the retention contract requires. The caller keeps observing
   for a bounded time; it is never reported as success. *)
type retention_probe =
  | Settled of retention
  | Pending of string

(* The retention queries are stated here too, so "what was actually asked" is one
   readable thing per promise rather than a flag list assembled at the edge. *)
let final_snapshot_query ~snapshot_id ~region =
  [ "aws"
  ; "rds"
  ; "describe-db-snapshots"
  ; "--db-snapshot-identifier"
  ; snapshot_id
  ; "--region"
  ; region
  ; "--output"
  ; "json"
  ]
;;

let instance_snapshots_query ~instance ~region =
  [ "aws"
  ; "rds"
  ; "describe-db-snapshots"
  ; "--db-instance-identifier"
  ; instance
  ; "--region"
  ; region
  ; "--output"
  ; "json"
  ]
;;

(* `{"DBSnapshots":[{"DBSnapshotIdentifier":..,"SnapshotType":..,"Status":..}]}`. *)
let snapshots_of_json stdout =
  try
    match Yojson.Safe.from_string stdout with
    | `Assoc _ as document ->
      (match Yojson.Safe.Util.member "DBSnapshots" document with
       | `List items ->
         Ok
           (List.map
              (fun item ->
                 let open Yojson.Safe.Util in
                 ( member "DBSnapshotIdentifier" item |> to_string_option
                 , member "SnapshotType" item |> to_string_option
                 , member "Status" item |> to_string_option ))
              items)
       | _ -> Error "the provider's answer carries no `DBSnapshots` array")
    | _ -> Error "the provider's answer is not a JSON object"
  with
  | Yojson.Json_error message -> Error ("the provider's answer is not JSON: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    Error ("the provider's answer has an unexpected shape: " ^ message)
;;

let transient_snapshot_status = function
  | "creating" | "pending" | "starting" -> true
  | _ -> false
;;

let snapshot_label (id, kind, _) =
  Printf.sprintf
    "%s%s"
    (Option.value id ~default:"<unnamed>")
    (match kind with
     | Some kind -> " (" ^ kind ^ ")"
     | None -> "")
;;

(* The promised final snapshot must exist *and* reach the state the retention
   contract requires -- `available`, not merely "a record exists". The identifier
   is the one established before destroy; a provider answer about a different
   identifier is not evidence about this one. *)
let classify_final_snapshot ~declared ~snapshot_id lookup =
  let policy = Sol_cli_cloud_lifecycle.destroy_retention_to_string declared in
  match lookup with
  | Unavailable reason ->
    Settled
      (Retention_unknown
         (Printf.sprintf "final snapshot %s could not be queried: %s" snapshot_id reason))
  | Answered { status = 0; stdout; _ } ->
    (match snapshots_of_json stdout with
     | Error message ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the provider's record for final snapshot %s could not be read: %s"
               snapshot_id
               message))
     | Ok snapshots ->
       (match List.find_opt (fun (id, _, _) -> id = Some snapshot_id) snapshots with
        | None ->
          Settled
            (Retention_violated
               (Printf.sprintf
                  "final-snapshot NOT observed (destroy_retention = %s): the provider's \
                   answer contains no snapshot %s%s"
                  policy
                  snapshot_id
                  (match snapshots with
                   | [] -> ""
                   | _ ->
                     " (it reported "
                     ^ String.concat ", " (List.map snapshot_label snapshots)
                     ^ ")")))
        | Some (_, _, Some "available") ->
          Settled
            (Retention_required_and_observed
               (Printf.sprintf
                  "final snapshot %s observed available (destroy_retention = %s, so the \
                   target outlives its compute; remove it with `aws rds \
                   delete-db-snapshot --db-snapshot-identifier %s` once it is no longer \
                   needed)"
                  snapshot_id
                  policy
                  snapshot_id))
        | Some (_, _, Some status) when transient_snapshot_status status ->
          Pending
            (Printf.sprintf
               "final snapshot %s exists and the provider reports it %s"
               snapshot_id
               status)
        | Some (_, _, Some status) ->
          Settled
            (Retention_violated
               (Printf.sprintf
                  "final-snapshot NOT observed (destroy_retention = %s): the provider \
                   reports snapshot %s as %s, which is not available"
                  policy
                  snapshot_id
                  status))
        | Some (_, _, None) ->
          Settled
            (Retention_unknown
               (Printf.sprintf
                  "the provider's record for final snapshot %s carries no status, so \
                   availability is not established"
                  snapshot_id))))
  | Answered { status; stderr; _ } ->
    (match aws_error_code stderr with
     | Some "DBSnapshotNotFound" ->
       Settled
         (Retention_violated
            (Printf.sprintf
               "final-snapshot NOT observed (destroy_retention = %s): the target \
                declared it keeps its final snapshot, and the provider explicitly \
                reports that %s does not exist"
               policy
               snapshot_id))
     | Some code ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the final snapshot query failed (%s, exit %d), so the retention \
                guarantee is not established: %s"
               code
               status
               (abbreviate stderr)))
     | None ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the final snapshot query failed with exit %d and no provider error code, \
                so the retention guarantee is not established: %s"
               status
               (abbreviate stderr))))
;;

(* Retain-nothing: no manual or automated snapshot attributable to this
   destruction may remain. The query is scoped by the *captured* database
   instance identifier -- the identity from the destruction transaction -- rather
   than by a broad name prefix, which is exactly the ambiguity to avoid. AWS
   documents that omitting `--snapshot-type` returns automated and manual
   snapshots (not shared/public/AWS-Backup ones), and that is what is checked. *)
let classify_instance_snapshots lookup =
  match lookup with
  | Unavailable reason ->
    Retention_unknown
      (Printf.sprintf
         "no-residue could not be observed: the snapshot query could not be run: %s"
         reason)
  | Answered { status = 0; stdout; _ } ->
    (match snapshots_of_json stdout with
     | Error message ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the provider's answer could not be read: \
             %s"
            message)
     | Ok [] ->
       Retention_required_and_observed
         "none observed (destroy_retention = none): the provider returns no manual or \
          automated snapshot for this target's database"
     | Ok snapshots ->
       Retention_violated
         (Printf.sprintf
            "retain-nothing NOT observed (destroy_retention = none): %d snapshot(s) \
             attributable to this destruction remain: %s"
            (List.length snapshots)
            (String.concat ", " (List.map snapshot_label snapshots))))
  | Answered { status; stderr; _ } ->
    (match aws_error_code stderr with
     | Some ("DBInstanceNotFound" | "InvalidDBInstanceId.NotFound") ->
       Retention_required_and_observed
         "none observed (destroy_retention = none): the provider reports no such \
          database instance, so no snapshot of it is retained"
     | Some code ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the snapshot query failed (%s, exit %d): \
             %s"
            code
            status
            (abbreviate stderr))
     | None ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the snapshot query failed with exit %d \
             and no provider error code: %s"
            status
            (abbreviate stderr)))
;;

(* Works for both Classic ELB and ALB/NLB uniformly: the in-cluster AWS
   cloud-controller tags every load balancer it creates for a Service with
   kubernetes.io/cluster/<cluster-name>, regardless of LB type. Only
   covers that in-tree tagging convention -- a load balancer created by the
   standalone AWS Load Balancer Controller instead tags primarily with
   elbv2.k8s.aws/cluster, which this does not check. Not a gap today
   (platform/cloud/modules/platform/main.tf only installs ingress-nginx, which uses
   the in-tree cloud-controller path), but would need extending if Sol
   ever supports the standalone LBC.

   Returns None (not a bool) on a query failure so callers can tell "no
   load balancers" apart from "couldn't check" -- the two calling sites
   below need to react differently to each. *)
let load_balancers_gone ~region ~cluster_name =
  let tag_key = Printf.sprintf "kubernetes.io/cluster/%s" cluster_name in
  match
    Sol_cli_process.run_success
      (Sol_cli_process.cmd
         [ "aws"
         ; "resourcegroupstaggingapi"
         ; "get-resources"
         ; "--resource-type-filters"
         ; "elasticloadbalancing"
         ; "--tag-filters"
         ; Printf.sprintf "Key=%s" tag_key
         ; "--query"
         ; "ResourceTagMappingList[].ResourceARN"
         ; "--output"
         ; "text"
         ; "--region"
         ; region
         ])
  with
  | Ok r -> Some (String.trim r.Sol_cli_process.stdout = "")
  | _ -> None
;;

let aws_load_balancer_probe ~region ~cluster_name =
  match load_balancers_gone ~region ~cluster_name with
  | Some true -> Probe_gone
  | Some false ->
    Probe_found
      (Printf.sprintf
         "AWS load balancer(s) still exist after destroy (tag kubernetes.io/cluster/%s)"
         cluster_name)
  | None ->
    Probe_indeterminate
      "AWS load balancers could not be checked: the aws CLI is unavailable or errored"
;;

(* The platform destroy removes the ingress Service through the named
   provisioner. AWS deprovisions its load balancer asynchronously, so wait
   before Terraform removes the VPC. The final absence check remains the hard
   gate if this best-effort wait times out. *)
let rec wait_for_load_balancers_gone ~region ~cluster_name attempts =
  if attempts = 0
  then
    Printf.printf
      "  (warning: load balancer(s) may still be deprovisioning; proceeding to cloud \
       destroy and retaining the final absence check)\n\
       %!"
  else (
    match load_balancers_gone ~region ~cluster_name with
    | Some true -> ()
    | Some false | None ->
      Unix.sleepf 5.;
      wait_for_load_balancers_gone ~region ~cluster_name (attempts - 1))
;;

(* INFRA-047: Terraform state being empty is not an absence proof for resources
   created indirectly by the VPC module or by Kubernetes. *)
let aws_list_probe ~region ~kind ~argv =
  match
    Sol_cli_process.output
      (Sol_cli_process.cmd (("aws" :: argv) @ [ "--region"; region ]))
  with
  | Ok listed when Sol_cli_string.is_blank listed -> Probe_gone
  | Ok listed ->
    Probe_found
      (Printf.sprintf "AWS %s still exist after destroy: %s" kind (String.trim listed))
  | Error (Sol_cli_process.Non_zero r) ->
    Probe_indeterminate
      (Printf.sprintf "AWS %s could not be checked: %s" kind (String.trim r.stderr))
  | Error _ ->
    Probe_indeterminate
      (Printf.sprintf "AWS %s could not be checked: the aws CLI is unavailable" kind)
;;

let aws_no_ebs_volumes ~region ~cluster_name =
  aws_list_probe
    ~region
    ~kind:"EBS volumes"
    ~argv:
      [ "ec2"
      ; "describe-volumes"
      ; "--filters"
      ; Printf.sprintf
          "Name=tag:kubernetes.io/cluster/%s,Values=owned,shared"
          cluster_name
      ; "--query"
      ; "Volumes[].VolumeId"
      ; "--output"
      ; "text"
      ]
;;

let aws_orphan_sweep ~pre_destroy ~region ~cluster =
  let cluster_name =
    match state_name pre_destroy "aws_eks_cluster" with
    | Some _ as name -> name
    | None -> Option.map (fun (cluster : Sol_cli_cluster.t) -> cluster.name) cluster
  in
  let region = Sol_cli_string.non_blank region in
  (* REFAC-093 / DEC-045: only what Terraform does not own is swept -- load
     balancers the in-cluster cloud controller creates, and volumes created for
     PersistentVolumeClaims. Elastic IPs, NAT gateways and ECR repositories are
     Terraform-managed (the VPC module and the root); a successful destroy plus the
     empty-state check is the authority for them. *)
  match region with
  | None ->
    orphan_sweep
      ~gaps:
        [ "the AWS residue checks could not establish the target's region, so they were \
           not run"
        ]
      []
  | Some region ->
    let cluster_probes, cluster_gap =
      match cluster_name with
      | Some cluster_name ->
        ( [ aws_load_balancer_probe ~region ~cluster_name
          ; aws_no_ebs_volumes ~region ~cluster_name
          ]
        , [] )
      | None ->
        ( []
        , [ "the AWS residue checks could not establish the target's cluster name from \
             Terraform state or the install outputs, so its tag-derived checks were not \
             run"
          ] )
    in
    orphan_sweep ~gaps:cluster_gap cluster_probes
;;

(* How long to keep observing a final snapshot that the provider reports as still
   being created. A snapshot that never reaches `available` is reported unknown --
   never as a met guarantee -- and this only bounds how long that takes to say.

   The interval is an operator knob (`SOL_DESTROY_SNAPSHOT_INTERVAL_S`), because a
   large database's final snapshot takes longer than a small one's. The offline
   harness sets it to 0 so the pending path is exercised without sleeping, and an
   unparseable value is refused loudly rather than silently replaced. *)
let final_snapshot_attempts = 12

(* REFAC-115: read when a destroy needs it, and refused there. As a top-level
   value it was evaluated at program start, so a malformed setting made every `sol`
   command -- `sol --version` included -- exit 2. *)
let final_snapshot_interval_s () =
  match Sys.getenv_opt "SOL_DESTROY_SNAPSHOT_INTERVAL_S" with
  | None -> Ok 10.
  | Some raw ->
    (match float_of_string_opt raw with
     | Some seconds when seconds >= 0. -> Ok seconds
     | _ ->
       Error
         (Printf.sprintf
            "SOL_DESTROY_SNAPSHOT_INTERVAL_S=%S is not a non-negative number of seconds"
            raw))
;;

let rec observe_final_snapshot ~interval ~declared ~snapshot_id ~region ~attempts =
  let lookup = run_provider_query (final_snapshot_query ~snapshot_id ~region) in
  match classify_final_snapshot ~declared ~snapshot_id lookup with
  | Settled retention -> retention
  | Pending message ->
    if attempts <= 0
    then
      Sol_cli_destroy_verification.Retention_unknown
        (Printf.sprintf
           "%s; the retention guarantee is not established while it has not reached \
            available"
           message)
    else (
      Unix.sleepf interval;
      observe_final_snapshot
        ~interval
        ~declared
        ~snapshot_id
        ~region
        ~attempts:(attempts - 1))
;;

let rds_target = Sol_cli_terraform.targets "aws_db_instance.postgres" []

let unique_rds_snapshot_id cluster_name =
  (* Millisecond resolution: a `.0f` second timestamp could collide if a
     destroy were retried within the same second. AWS snapshot identifiers
     disallow `.`, hence the truncated int rather than a raw float. *)
  Printf.sprintf
    "%s-postgres-final-%d"
    cluster_name
    (int_of_float (Unix.gettimeofday () *. 1000.))
;;

(* The RDS instance, by its real declared address. Finding it by address rather
   than by type is the FND-0048 correction: a second [aws_db_instance] (a read
   replica) is a different address and is never mistaken for this one. An
   unreadable state is UNKNOWN, never "no instance". *)
let rds_of_state state =
  let open Sol_cli_cloud_destroy in
  match find_address state "aws_db_instance.postgres" with
  | Some resource when resource.kind = "aws_db_instance" ->
    (match resource.deletion_protection with
     | Some deletion_protection ->
       Ok
         (Some
            ( deletion_protection
            , resource.final_snapshot_identifier
            , resource.skip_final_snapshot ))
     | None -> Error "RDS deletion_protection is absent from its state representation")
  | Some resource ->
    Error
      (Printf.sprintf
         "address aws_db_instance.postgres is a %s, not an aws_db_instance"
         resource.kind)
  | None ->
    (match substrate_presence state with
     | Substrate_unknown -> Error "could not read this target's state"
     | Substrate_present | Substrate_absent -> Ok None)
;;

(* ADR 0002 / HARDEN-002 finding 9b: lifting RDS deletion protection is a
   state transition (ModifyDBInstance), and a destroy plan contains only
   deletes -- a `-var` passed to `terraform destroy` never reaches the
   provider, which is handed prior state (see the now-resolved comment this
   replaced). Preparation is therefore its own targeted apply against just
   the RDS resource, with a snapshot identity unique to this destroy attempt
   so re-running destroy after a fresh apply can never collide with a prior
   attempt's final snapshot. *)
(* HARDEN-004 step 4: the preparation declares the consequence of its own failure,
   and the policy is a function of the *target's* own declaration rather than a
   provider special case inside the execution core. AWS's final-snapshot mode is the
   canonical [Block_destroy] -- its failure stands for the declared retention
   guarantee (DEC-033). A disposable target that retains nothing has no such
   guarantee to lose, so a failure there is best-effort and destruction continues.
   GCP's analogue of the guarantee ("Sol cannot retain anything on GCP yet") carries
   [Block_destroy] where it is produced, in [Sol_cli_gcp_destruction.prepare]. *)
let aws_preparation_policy ~retention =
  match retention with
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot -> Sol_cli_cloud_lifecycle.Block_destroy
  | Sol_cli_cloud_lifecycle.Retain_nothing -> Sol_cli_cloud_lifecycle.Continue_to_destroy
;;

(* A blocked preparation must name the guarantee that blocked it, so the operator
   reads *why* the target was left standing rather than a bare apply failure. *)
let aws_preparation_reason ~retention reason =
  match retention with
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
    Printf.sprintf
      "the target's destroy_retention is final-snapshot, so its declared retention \
       guarantee could not be established before destroying: %s"
      reason
  | Sol_cli_cloud_lifecycle.Retain_nothing -> reason
;;

let prepare_destroy_result run_log infra_dir var_files vars ~cluster_name ~retention state
  : string Sol_cli_cloud_lifecycle.preparation_outcome
  =
  (* Qualified deliberately: `Sol_cli_cloud_lifecycle` also exports a
     `cluster_name` function, and opening it would shadow this parameter. *)
  let failed reason =
    Sol_cli_cloud_lifecycle.Preparation_failed
      { reason = aws_preparation_reason ~retention reason
      ; policy = aws_preparation_policy ~retention
      }
  in
  match rds_of_state state with
  | Error message -> failed message
  | Ok None ->
    Printf.printf "  prepare: no RDS instance for this target, nothing to prepare.\n%!";
    Sol_cli_cloud_lifecycle.Nothing_to_prepare
  | Ok (Some _) ->
    let snapshot_id = unique_rds_snapshot_id cluster_name in
    Printf.printf
      "  prepare: disabling RDS deletion protection%s...\n%!"
      (match retention with
       | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
         ", final snapshot " ^ snapshot_id
       | Sol_cli_cloud_lifecycle.Retain_nothing -> ", retaining nothing");
    (match
       apply_asserted
         ~run_log
         ~phase_name:"rds-destroy-prepare"
         ~policy:
           (Sol_cli_cloud_destroy.guard_preparation_policy
              ~addresses:[ "aws_db_instance.postgres" ])
         ~scope:rds_target
         ~chdir:infra_dir
         ~var_files
         ~vars:
           (vars
            @ [ "rds_deletion_protection=false" ]
            @
            match retention with
            | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
              [ "rds_skip_final_snapshot=false"
              ; "rds_final_snapshot_identifier=" ^ snapshot_id
              ]
            | Sol_cli_cloud_lifecycle.Retain_nothing -> [ "rds_skip_final_snapshot=true" ]
           )
         ()
     with
     | Error message -> failed message
     | Ok () -> Sol_cli_cloud_lifecycle.Prepared snapshot_id)
;;

(* DEC-033: what "prepared" means depends on what the target selected, so the
   verification is driven by the policy rather than by a single expected value.

     final-snapshot -> deletion protection disabled, snapshot creation ENABLED,
                       and the identifier is the one this run prepared
     none           -> deletion protection disabled, snapshot creation DISABLED,
                       and no identifier is required

   Deliberately not `if actual <> "" then check_identifier`: that would let a
   missing identifier pass for a target that explicitly asked to keep its snapshot,
   which is the production guarantee this must not weaken. *)
let verify_destroy_preparation_result infra_dir ~retention ~prepared =
  match prepared with
  | None ->
    Printf.printf "  verify preparation: nothing was prepared.\n%!";
    Ok ()
  | Some snapshot_id ->
    let* state = read_cloud_state infra_dir in
    (match rds_of_state state with
     | Error message -> Error message
     | Ok None ->
       Error "RDS destroy preparation ran but the instance is now absent from state"
     | Ok (Some (deletion_protection, final_snapshot_identifier, skip_final_snapshot)) ->
       let* () =
         if deletion_protection
         then Error "RDS deletion protection is still enabled after preparation"
         else Ok ()
       in
       let* () =
         match retention with
         | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
           let* () =
             match skip_final_snapshot with
             | Some true ->
               Error
                 "the target retains its final snapshot, but preparation disabled \
                  snapshot creation"
             | None ->
               Error
                 "cannot establish that the final snapshot will be retained: \
                  skip_final_snapshot is absent from state"
             | Some false -> Ok ()
           in
           if final_snapshot_identifier <> Some snapshot_id
           then
             Error
               (Printf.sprintf
                  "RDS final snapshot identifier is %s, expected the prepared %s"
                  (Option.value final_snapshot_identifier ~default:"<none>")
                  snapshot_id)
           else Ok ()
         | Sol_cli_cloud_lifecycle.Retain_nothing ->
           (match skip_final_snapshot with
            | Some true -> Ok ()
            | Some false ->
              Error
                "the target retains nothing, but preparation left snapshot creation \
                 enabled"
            | None ->
              Error
                "cannot establish that snapshot creation is disabled: \
                 skip_final_snapshot is absent from state")
       in
       Printf.printf
         "  verify preparation: RDS deletion protection disabled, final snapshot %s \
          (target destroy_retention = %s)\n\
          %!"
         (match retention with
          | Sol_cli_cloud_lifecycle.Retain_final_snapshot -> snapshot_id ^ " confirmed"
          | Sol_cli_cloud_lifecycle.Retain_nothing ->
            (* Say what will happen, not just the setting: `skip_final_snapshot=true`
               reads as "enabled" to anyone skimming, which is the opposite of what
               it means. *)
            Printf.sprintf
              "skipped (skip_final_snapshot=%s)"
              (match skip_final_snapshot with
               | Some value -> string_of_bool value
               | None -> "absent"))
         (Sol_cli_cloud_lifecycle.destroy_retention_to_string retention);
       Ok ())
;;

(* Retention, observed. What is checked is stated for each mode rather than
   inferred: the promised snapshot must exist *and* be available, and a target that
   keeps nothing must have no manual or automated snapshot attributable to its own
   captured database identity. *)
let observe_retention ~region ~retention ~pre_destroy ~preparation =
  (* REFAC-094: the database this destruction owned, from Terraform state -- its
     `identifier` is what a retain-nothing target must leave no snapshot of. The
     region is the target's declared one, which the AWS root is configured in. *)
  let database =
    List.find_opt
      (fun (resource : Sol_cli_cloud_destroy.resource) ->
         String.equal resource.kind "aws_db_instance")
      (Sol_cli_cloud_destroy.resources pre_destroy)
  in
  let region = Sol_cli_string.non_blank region in
  match preparation with
  | Sol_cli_cloud_destroy.Nothing_prepared ->
    Retention_not_required
      "nothing to decide -- this target had no database whose retention a destroy had to \
       settle"
  | Sol_cli_cloud_destroy.Prepared { retained = None } ->
    Retention_unknown
      "an AWS destroy reported a preparation with no snapshot identity, so there is no \
       retention identity to observe"
  | Sol_cli_cloud_destroy.Prepared { retained = Some snapshot_id } ->
    (match retention with
     | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
       (match region with
        | Some region ->
          (match final_snapshot_interval_s () with
           | Ok interval ->
             observe_final_snapshot
               ~interval
               ~declared:retention
               ~snapshot_id
               ~region
               ~attempts:final_snapshot_attempts
           | Error reason ->
             (* [prepare] refuses this before destroying; kept total, not trusted. *)
             Retention_unknown reason)
        | None ->
          Retention_unknown
            (Printf.sprintf
               "the promised final snapshot %s could not be queried: the target declares \
                no region"
               snapshot_id))
     | Sol_cli_cloud_lifecycle.Retain_nothing ->
       (match database with
        | None ->
          Retention_not_required
            "nothing to decide -- this target had no database whose retention a destroy \
             had to settle"
        | Some database ->
          (match database.identifier, region with
           | Some instance, Some region ->
             classify_instance_snapshots
               (run_provider_query (instance_snapshots_query ~instance ~region))
           | _ ->
             Retention_unknown
               "no-residue could not be observed: Terraform state records no database \
                identifier, or the target declares no region")))
;;

(* The verification is part of the preparation: a snapshot identity that could not
   be confirmed is not a preparation. *)
let prepare { run_log; infra_dir; var_files; vars; _ } ~retention ~cluster_name ~state =
  (* The verification is part of the preparation: a snapshot identity that could
     not be confirmed is not a preparation, and it fails with the same
     consequence the preparation would have (final-snapshot blocks). *)
  match retention, final_snapshot_interval_s () with
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot, Error reason ->
    (* The interval polls for the promised final snapshot: refuse before anything
       is destroyed rather than after. *)
    Sol_cli_cloud_lifecycle.Preparation_failed
      { reason; policy = Sol_cli_cloud_lifecycle.Block_destroy }
  | _ ->
    (match
       prepare_destroy_result
         run_log
         infra_dir
         var_files
         vars
         ~cluster_name
         ~retention
         state
     with
     | Sol_cli_cloud_lifecycle.Prepared snapshot_id ->
       (match
          verify_destroy_preparation_result
            infra_dir
            ~retention
            ~prepared:(Some snapshot_id)
        with
        | Ok () ->
          Sol_cli_cloud_lifecycle.Prepared
            (Sol_cli_cloud_destroy.Prepared { retained = Some snapshot_id })
        | Error reason ->
          Sol_cli_cloud_lifecycle.Preparation_failed
            { reason = aws_preparation_reason ~retention reason
            ; policy = aws_preparation_policy ~retention
            })
     | Sol_cli_cloud_lifecycle.Nothing_to_prepare ->
       Sol_cli_cloud_lifecycle.Nothing_to_prepare
     | Sol_cli_cloud_lifecycle.Preparation_failed failure ->
       Sol_cli_cloud_lifecycle.Preparation_failed failure)
;;

(* The platform destroy removes the ingress Service; AWS deprovisions its load
   balancer asynchronously, so wait before Terraform removes the VPC. *)
let before_substrate_destroy ctx () =
  match ctx.resolved_var "cluster_name" with
  | None -> ()
  | Some cluster_name ->
    let region = Option.value (ctx.resolved_var "region") ~default:"us-east-1" in
    wait_for_load_balancers_gone ~region ~cluster_name 24
;;

let destruction ctx : Sol_cli_destruction.t =
  { prepare = prepare ctx
  ; retention =
      (fun ~retention ~pre_destroy ~preparation ->
        observe_retention ~region:ctx.target.region ~retention ~pre_destroy ~preparation)
  ; residue =
      (fun ~pre_destroy ~cluster ->
        aws_orphan_sweep ~pre_destroy ~region:ctx.target.region ~cluster)
  ; before_substrate_destroy = before_substrate_destroy ctx
  }
;;
