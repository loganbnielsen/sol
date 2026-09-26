(* REFAC-097 (plan stage S9): what a provider does for a destroy beyond Terraform,
   as the lifecycle sees it.

   Sol owns `destroy_retention`; each provider answers how it honours it -- a
   preparation, and an observation of what survived -- or refuses with the reason,
   which the sequence maps to [Block_destroy]. Residue is the provider's own
   observation of objects Terraform does not own. The provider modules
   (Sol_cli_aws_destruction, Sol_cli_gcp_destruction) build a [t]; the generic code
   receives no ARN, self-link, resource ID or query recipe, only verdicts. *)

(* Text helpers the providers' evidence classifiers share. *)
let abbreviate ?(limit = 400) text =
  let text = String.trim text in
  if String.length text <= limit then text else String.sub text 0 limit ^ "..."
;;

(* ── the orphan sweep (HARDEN-004 step 5) ────────────────────────────────────

   These are the name/tag-derived checks that used to *be* the whole verification.
   They still catch what Terraform's own state cannot speak for -- EBS volumes
   created for PersistentVolumeClaims, load balancers created by the in-tree cloud
   controller, the service-networking peering GCP refuses to delete while a
   producer is registered (INFRA-047). Kinds Terraform manages itself (elastic IPs,
   NAT gateways, ECR repositories) are not swept: its destroy plus the empty-state
   check is their authority (DEC-045, REFAC-093). They are **secondary**, and their
   type says so:

   - [Probe_gone] / [Probe_found] are answers about the resources;
   - [Probe_indeterminate] means the check established nothing (an API error, a
     missing tool, a query context that could not be reconstructed). It is
     reported, and it is never read as absence.

   Two things follow, and both matter. A guessed name can no longer be the reason a
   captured identity is declared gone, and it can no longer turn an UNKNOWN
   observation into a pass. Where a query context is needed, it is taken from the
   identity captured *before* destruction (the network the inventory represents,
   the region in a captured ARN) or from the target's own configuration -- and if
   neither is available the check reports that it could not run rather than
   guessing a name and reading the miss as absence (step 5 section 5). *)

type probe_outcome =
  | Probe_gone
  | Probe_found of string
  | Probe_indeterminate of string

let orphan_sweep ?(gaps = []) probes : Sol_cli_destroy_verification.sweep =
  let residues =
    List.filter_map
      (function
        | Probe_found r -> Some r
        | _ -> None)
      probes
  in
  let indeterminate =
    gaps
    @ List.filter_map
        (function
          | Probe_indeterminate r -> Some r
          | _ -> None)
        probes
  in
  Sol_cli_destroy_verification.Sweep_ran { residues; indeterminate }
;;

(* The `name` Terraform recorded for the first represented resource of [kind]
   (REFAC-094). The residue checks ask about objects Terraform does not own by
   reference to ones it did -- the cluster a load balancer belongs to, the network
   a peering is on -- and take that name from state rather than rebuilding it from
   a naming convention. *)
let state_name pre_destroy kind =
  List.find_map
    (fun (resource : Sol_cli_cloud_destroy.resource) ->
       if String.equal resource.kind kind then resource.name else None)
    (Sol_cli_cloud_destroy.resources pre_destroy)
;;

(* ── HARDEN-004 step 5: the observation ────────────────────────────────────── *)

let run_provider_query argv : Sol_cli_destroy_verification.lookup_result =
  match Sol_cli_process.run (Sol_cli_process.cmd argv) with
  | Ok result ->
    Sol_cli_destroy_verification.Answered
      { status = result.Sol_cli_process.exit_code
      ; stdout = result.stdout
      ; stderr = result.stderr
      }
  | Error error -> Unavailable (Sol_cli_process.error_to_string error)
;;

(* This root's own applied state, not the named cross-root output contract in
   Sol_cli_cloud_lifecycle -- that contract exists for wiring the platform
   root, not for a root checking its own resource against itself. [Ok None]
   means the instance does not exist (create_rds = false), which is
   trivially prepared for destruction. *)
(* HARDEN-004 step 2 / REFAC-091: the state inventory.

   The destroy path takes ONE observation of the root's own applied state and
   turns it into the typed inventory in [Sol_cli_cloud_destroy]. Every decision
   below -- what is represented, which guarded resources may be targeted, what
   verification has to see -- is derived from that inventory. It is deliberately
   NOT derived from the install-time output contract: a half-built target may
   have no outputs, partial outputs, or complete outputs, and none of those decide
   whether destruction is available (FND-0044 point 2). *)
let read_cloud_state infra_dir : (Sol_cli_cloud_destroy.state_read, string) result =
  match Sol_cli_terraform.show_json ~chdir:infra_dir () with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    Ok (Sol_cli_cloud_destroy.inventory_of_show_json result.Sol_cli_process.stdout)
  | Ok result ->
    Error (Printf.sprintf "terraform show failed with exit %d" result.exit_code)
  | Error error ->
    Error ("could not read terraform state: " ^ Sol_cli_process.error_to_string error)
;;

(* What every provider's destruction steps are run with. [resolved_var] reads a
   `-var` / var-file value the caller passed, for the provider glue that needs one. *)
type context =
  { run_log : Sol_cli_run_log.t
  ; infra_dir : string
  ; var_files : string list
  ; vars : string list
  ; target : Sol_cli_config.target
  ; resolved_var : string -> string option
  }

type t =
  { prepare :
      retention:Sol_cli_cloud_lifecycle.destroy_retention
      -> cluster_name:string
      -> state:Sol_cli_cloud_destroy.state_read
      -> Sol_cli_cloud_destroy.preparation Sol_cli_cloud_lifecycle.preparation_outcome
    (** Settle what the destroy will keep, and lower the deletion guards. A provider
      that cannot honour [retention] answers [Preparation_failed] with
      [Block_destroy] and the reason. *)
  ; retention :
      retention:Sol_cli_cloud_lifecycle.destroy_retention
      -> pre_destroy:Sol_cli_cloud_destroy.state_read
      -> preparation:Sol_cli_cloud_destroy.preparation
      -> Sol_cli_destroy_verification.retention
    (** After the destroy: what the provider observes of what it promised to keep. *)
  ; residue :
      pre_destroy:Sol_cli_cloud_destroy.state_read
      -> cluster:Sol_cli_cluster.t option
      -> Sol_cli_destroy_verification.sweep
    (** After the destroy: objects Terraform does not own that the target left. *)
  ; before_substrate_destroy : unit -> unit
    (** Provider glue that must run before the substrate destroy needs it. *)
  }
