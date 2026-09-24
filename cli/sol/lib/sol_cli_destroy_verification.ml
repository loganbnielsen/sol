(* HARDEN-004 step 5 — verifying destruction from observed provider/state evidence.

   Steps 2-4 established what destruction is *allowed* to do. This module
   establishes what Sol is justified in *claiming* happened. The governing rule is

     failure to obtain evidence is not evidence of the desired postcondition

   and its destruction-specific form

     a successful destroy command is not itself evidence that the target is
     absent.

   Three things live here, and they are deliberately separate:

   - **identity**: the provider identity captured from the pre-destroy
     Terraform-state observation. Verification queries *that* identity -- never
     one reconstructed from a workspace name, a naming convention, a fallback
     region, a line-based tfvars read, the current configuration or the install
     outputs. The rule is "observe identity before mutation; verify that same
     identity after mutation". The name-derived lookups still exist, but they are
     a *secondary* orphan sweep ([sweep]) and can never override the captured
     identities' evidence.

   - **evidence**: three-valued provider answers ([Present] / [Absent] /
     [Unknown]), an independent post-destroy Terraform-state observation, the
     demoted orphan sweep, and observed retention. The vocabulary deliberately
     matches the qualification harness's, which reached the same conclusion live:
     Attempt 4 showed that a non-zero exit read as ABSENT is how a check "that
     cannot recognise absence" makes Absent unreachable, and #449 fixed the same
     class one level down.

   - **classification** ([classify]): what the evidence does and does not
     establish. Nothing here collapses a disagreement between evidence sources
     into one boolean, and UNKNOWN is never read as ABSENT. At minimum, three
     states are distinguished: positively verified, positively violated, and
     unverifiable.

   The module is pure. Every process invocation is injected by the caller
   ([query_of] produces the argv, [lookup_result] carries what running it
   returned), so every case is testable without a cloud (step 5 section 8). *)

(* ── Captured provider identity ─────────────────────────────────────────────

   What the pre-destroy inventory holds for one represented resource. This is the
   *input* to verification, not something verification re-derives. *)

type identity =
  { address : string
  ; kind : string
  ; provider_id : string option
    (* The provider's own id/self-link: the CLI-usable name for every recipe
         below. *)
  ; arn : string option
    (* The fully-qualified cloud identifier, where the provider publishes one.
         For AWS it is also the only place an individual resource's region is
         recorded. *)
  ; project : string option (* GCP project, or the AWS account id. *)
  ; region : string option (* Region/location; a zone is reduced to its region. *)
  }

let identity_to_string identity =
  Printf.sprintf
    "%s [%s]%s%s%s%s"
    identity.address
    identity.kind
    (match identity.provider_id with
     | Some id -> " id=" ^ id
     | None -> "")
    (match identity.arn with
     | Some arn -> " arn=" ^ arn
     | None -> "")
    (match identity.project with
     | Some project -> " project=" ^ project
     | None -> "")
    (match identity.region with
     | Some region -> " region=" ^ region
     | None -> "")
;;

let ( let* ) = Result.bind

(* ── Path/ARN parsing, shared with the inventory ───────────────────────────── *)

let path_segments path = String.split_on_char '/' path |> List.filter (fun s -> s <> "")

let segment_after ~marker path =
  let rec loop = function
    | a :: b :: _ when a = marker -> Some b
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop (path_segments path)
;;

let last_segment path =
  match List.rev (path_segments path) with
  | last :: _ -> Some last
  | [] -> None
;;

let has_segment ~segment path = List.mem segment (path_segments path)

(* `arn:partition:service:region:account-id:resource`. A global service leaves the
   region field empty; an ARN always carries the region field, so a blank one is
   "global", not "unknown". *)
let region_of_arn arn =
  match String.split_on_char ':' arn with
  | _ :: _ :: _ :: region :: _ when region <> "" -> Some region
  | _ -> None
;;

let account_of_arn arn =
  match String.split_on_char ':' arn with
  | _ :: _ :: _ :: _ :: account :: _ when account <> "" -> Some account
  | _ -> None
;;

(* The provider's own short name for an object: the last path segment of its
   id/self-link. The recipes below read it from the captured identity, and so does
   the name-derived orphan sweep, so "the object the provider knows" is spelled one
   way rather than two. *)
let object_name identity = Option.bind identity.provider_id last_segment

let contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec at i =
    if needle_length = 0
    then true
    else if i + needle_length > haystack_length
    then false
    else if String.sub haystack i needle_length = needle
    then true
    else at (i + 1)
  in
  at 0
;;

let abbreviate ?(limit = 400) text =
  let text = String.trim text in
  if String.length text <= limit then text else String.sub text 0 limit ^ "..."
;;

(* ── What running a provider query returned ────────────────────────────────── *)

type lookup_result =
  | Answered of
      { status : int
      ; stdout : string
      ; stderr : string
      }
  | Unavailable of string
(* The tool could not be run at all (absent from PATH, not executable,
         refused to start). Never absence: nothing was asked. *)

(* ── The provider lookup for one captured identity ─────────────────────────── *)

(* A provider's own "this does not exist" signal. AWS publishes a typed error code
   and the CLI prints it in a fixed position, so it is extracted structurally
   rather than guessed at; gcloud has no structured result, so its absence
   wordings are matched explicitly (Attempt 4: a deleted cluster answered
   `code=404`, and a check that recognised only `NOT_FOUND`/`was not found` made
   Absent unreachable -- while a check that accepted any non-zero exit would have
   read a permission failure as absence). *)
type not_found =
  | Aws_error_code of string
  | Gcp_absence_wording

type recipe =
  { identity : identity
  ; operation : string (* the exact query, for the operator *)
  ; argv : string list
  ; not_found : not_found
  }

(* What can be asked about one captured identity. The three answers are not two:
   "this kind has no provider lookup, so the state postcondition is the only claim
   being made" is a *coverage* statement, while "this kind does have one, but the
   captured identity is not enough to build it" is an observation that came back
   empty -- UNKNOWN, and therefore a failure. Collapsing them would either invent
   absence or silently drop coverage. *)
type queryability =
  | Queryable of recipe
  | No_recipe of string
  | Identity_incomplete of string

type provider_verdict =
  | Present (* the provider returned the resource *)
  | Absent (* the provider explicitly said it does not exist *)
  | Unknown of string (* permission, auth, timeout, transport, malformed, other *)

type provider_observation =
  { identity : identity
  ; operation : string
  ; status : int option (* [None] when the tool could not be run at all *)
  ; evidence : string (* the provider's own answer, abbreviated, for re-reading *)
  ; verdict : provider_verdict
  }

let missing identity what =
  Error (Printf.sprintf "%s: the captured identity carries no %s" identity.address what)
;;

let captured identity what = function
  | Some value -> Ok value
  | None -> missing identity what
;;

let query ~identity ~not_found argv =
  Ok { identity; operation = String.concat " " argv; argv; not_found }
;;

(* A GCP lookup, with the project the query was actually made in recorded on the
   recipe's identity. The self-link's project is stronger than any attribute, so
   "the identity queried" and "the context a not-found is checked against" have to
   be the same value -- otherwise a 404 about another project could be read as
   absence for ours (finding C). *)
let gcp_query ~identity ~project ~not_found argv =
  query ~identity:{ identity with project = Some project } ~not_found argv
;;

let queryable = function
  | Ok recipe -> Queryable recipe
  | Error reason -> Identity_incomplete reason
;;

let require_link identity =
  match identity.provider_id with
  | Some link -> Ok link
  | None -> missing identity "provider id or self-link"
;;

let project_of identity link =
  match segment_after ~marker:"projects" link with
  | Some project -> Ok project
  | None -> captured identity "project" identity.project
;;

let gcp_region_of identity link =
  match segment_after ~marker:"regions" link with
  | Some region -> Ok region
  | None -> captured identity "region" identity.region
;;

let aws_region_of identity = captured identity "region (from its ARN)" identity.region

(* ── The recipes ────────────────────────────────────────────────────────────

   One per resource kind whose absence the provider API can be asked about, built
   only from what the inventory captured. The site and object come out of the
   provider's own self-link (GKE's location in particular is the provider's own
   location, verbatim -- not a region derived from a zone, which would be a guess
   that a wrong lookup would report as absence). The project and region fall back
   to the resource's own attributes only when the identity path does not carry
   them, and never to the target's configuration.

   A kind with no recipe here is not quietly skipped: it is reported as not
   provider-verified, and its absence rests on the Terraform-state postcondition
   alone (see [unqueried]).

   Recipe correctness against a live provider is a claim like any other: it is
   derived from the documented CLI surface and has not been exercised live
   (HARDEN-004 step 5 authorizes no live operation). A wrong AWS error code fails
   closed (a genuinely-absent resource reads UNKNOWN and the destroy fails
   loudly); a wrong GCP location would fail open, which is why no recipe derives
   one. *)

let gcp_recipe identity : queryability =
  match identity.kind with
  | "google_container_cluster" ->
    queryable
      (let* link = require_link identity in
       let* name =
         captured identity "cluster name in its self-link" (last_segment link)
       in
       let* location =
         captured
           identity
           "location in its self-link"
           (segment_after ~marker:"locations" link)
       in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"
         ; "container"
         ; "clusters"
         ; "describe"
         ; name
         ; "--location"
         ; location
         ; "--project"
         ; project
         ])
  | "google_sql_database_instance" ->
    queryable
      (let* link = require_link identity in
       let* name =
         captured identity "instance name in its self-link" (last_segment link)
       in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"; "sql"; "instances"; "describe"; name; "--project"; project ])
  | "google_compute_network" ->
    queryable
      (let* link = require_link identity in
       let* name =
         captured identity "network name in its self-link" (last_segment link)
       in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"; "compute"; "networks"; "describe"; name; "--project"; project ])
  | "google_compute_subnetwork" ->
    queryable
      (let* link = require_link identity in
       let* name =
         captured identity "subnetwork name in its self-link" (last_segment link)
       in
       let* region = gcp_region_of identity link in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"
         ; "compute"
         ; "subnetworks"
         ; "describe"
         ; name
         ; "--region"
         ; region
         ; "--project"
         ; project
         ])
  | "google_compute_router" ->
    queryable
      (let* link = require_link identity in
       let* name = captured identity "router name in its self-link" (last_segment link) in
       let* region = gcp_region_of identity link in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"
         ; "compute"
         ; "routers"
         ; "describe"
         ; name
         ; "--region"
         ; region
         ; "--project"
         ; project
         ])
  | "google_compute_address" ->
    queryable
      ((* A regional address lives under `regions/<r>/addresses/<n>`, a global one
         under `global/addresses/<n>`; the self-link says which, so no target
         attribute has to be consulted for the scope. *)
       let* link = require_link identity in
       let* name =
         captured identity "address name in its self-link" (last_segment link)
       in
       let* scope =
         if has_segment ~segment:"global" link
         then Ok [ "--global" ]
         else
           let* region = gcp_region_of identity link in
           Ok [ "--region"; region ]
       in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         ([ "gcloud"; "compute"; "addresses"; "describe"; name ]
          @ scope
          @ [ "--project"; project ]))
  | "google_compute_global_address" ->
    queryable
      (let* link = require_link identity in
       let* name =
         captured identity "address name in its self-link" (last_segment link)
       in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"
         ; "compute"
         ; "addresses"
         ; "describe"
         ; name
         ; "--global"
         ; "--project"
         ; project
         ])
  | "google_artifact_registry_repository" ->
    queryable
      (let* link = require_link identity in
       let* name = captured identity "repository name in its id" (last_segment link) in
       let* location =
         match segment_after ~marker:"locations" link with
         | Some location -> Ok location
         | None -> captured identity "region/location" identity.region
       in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"
         ; "artifacts"
         ; "repositories"
         ; "describe"
         ; name
         ; "--location"
         ; location
         ; "--project"
         ; project
         ])
  | "google_storage_bucket" ->
    queryable
      (let* link = require_link identity in
       let* name = captured identity "bucket name in its self-link" (last_segment link) in
       let* project = captured identity "project" identity.project in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"
         ; "storage"
         ; "buckets"
         ; "describe"
         ; "gs://" ^ name
         ; "--project"
         ; project
         ])
  | "google_dns_managed_zone" ->
    queryable
      (let* link = require_link identity in
       let* name = captured identity "zone name in its id" (last_segment link) in
       let* project = project_of identity link in
       gcp_query
         ~identity
         ~project
         ~not_found:Gcp_absence_wording
         [ "gcloud"; "dns"; "managed-zones"; "describe"; name; "--project"; project ])
  | _ ->
    No_recipe
      (Printf.sprintf
         "%s: no GCP provider lookup is defined for %s"
         identity.address
         identity.kind)
;;

let aws_recipe identity : queryability =
  match identity.kind with
  | "aws_eks_cluster" ->
    queryable
      (let* name = captured identity "id (the cluster name)" identity.provider_id in
       let* region = aws_region_of identity in
       query
         ~identity
         ~not_found:(Aws_error_code "ResourceNotFoundException")
         [ "aws"; "eks"; "describe-cluster"; "--name"; name; "--region"; region ])
  | "aws_db_instance" ->
    queryable
      (let* id =
         captured identity "id (the DB instance identifier)" identity.provider_id
       in
       let* region = aws_region_of identity in
       query
         ~identity
         ~not_found:(Aws_error_code "DBInstanceNotFound")
         [ "aws"
         ; "rds"
         ; "describe-db-instances"
         ; "--db-instance-identifier"
         ; id
         ; "--region"
         ; region
         ])
  | "aws_ecr_repository" ->
    queryable
      (let* name = captured identity "id (the repository name)" identity.provider_id in
       let* region = aws_region_of identity in
       query
         ~identity
         ~not_found:(Aws_error_code "RepositoryNotFoundException")
         [ "aws"
         ; "ecr"
         ; "describe-repositories"
         ; "--repository-names"
         ; name
         ; "--region"
         ; region
         ])
  | "aws_s3_bucket" ->
    queryable
      (let* name = captured identity "id (the bucket name)" identity.provider_id in
       query
         ~identity
         ~not_found:(Aws_error_code "NoSuchBucket")
         [ "aws"; "s3api"; "get-bucket-location"; "--bucket"; name ])
  | "aws_vpc" ->
    queryable
      (let* id = captured identity "id" identity.provider_id in
       let* region = aws_region_of identity in
       query
         ~identity
         ~not_found:(Aws_error_code "InvalidVpcID.NotFound")
         [ "aws"; "ec2"; "describe-vpcs"; "--vpc-ids"; id; "--region"; region ])
  | "aws_subnet" ->
    queryable
      (let* id = captured identity "id" identity.provider_id in
       let* region = aws_region_of identity in
       query
         ~identity
         ~not_found:(Aws_error_code "InvalidSubnetID.NotFound")
         [ "aws"; "ec2"; "describe-subnets"; "--subnet-ids"; id; "--region"; region ])
  | "aws_security_group" ->
    queryable
      (let* id = captured identity "id" identity.provider_id in
       let* region = aws_region_of identity in
       query
         ~identity
         ~not_found:(Aws_error_code "InvalidGroup.NotFound")
         [ "aws"
         ; "ec2"
         ; "describe-security-groups"
         ; "--group-ids"
         ; id
         ; "--region"
         ; region
         ])
  | "aws_nat_gateway" ->
    queryable
      (let* id = captured identity "id" identity.provider_id in
       let* region = aws_region_of identity in
       query
         ~identity
         ~not_found:(Aws_error_code "NatGatewayNotFound")
         [ "aws"
         ; "ec2"
         ; "describe-nat-gateways"
         ; "--nat-gateway-ids"
         ; id
         ; "--region"
         ; region
         ])
  | _ ->
    No_recipe
      (Printf.sprintf
         "%s: no AWS provider lookup is defined for %s"
         identity.address
         identity.kind)
;;

let query_of ~provider identity : queryability =
  match provider with
  | Sol_cli_provider.Gcp -> gcp_recipe identity
  | Sol_cli_provider.Aws -> aws_recipe identity
;;

(* ── Classifying a provider answer ─────────────────────────────────────────── *)

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
      (fun needle -> contains ~needle text)
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

let classify_lookup recipe lookup =
  match lookup with
  | Unavailable reason -> Unknown reason
  | Answered { status = 0; _ } -> Present
  | Answered { status; stderr; _ } ->
    let absent =
      match recipe.not_found with
      | Aws_error_code code -> contains ~needle:code stderr
      | Gcp_absence_wording -> gcp_absence_message ?project:recipe.identity.project stderr
    in
    if absent
    then Absent
    else
      Unknown
        (Printf.sprintf
           "the provider answered exit %d without saying the resource is absent: %s"
           status
           (match String.trim stderr with
            | "" -> "(no diagnostic)"
            | text -> abbreviate text))
;;

(* The two record types share [identity] and [operation], so the parameter is
   annotated: without it the record literal below decides both types at once and
   resolves [recipe] to a [provider_observation]. *)
let observation_of_lookup ~(recipe : recipe) lookup =
  { identity = recipe.identity
  ; operation = recipe.operation
  ; status =
      (match lookup with
       | Answered { status; _ } -> Some status
       | Unavailable _ -> None)
  ; evidence =
      (match lookup with
       | Unavailable reason -> reason
       | Answered { status; stdout; stderr } ->
         let diagnostic = String.trim stderr in
         if diagnostic <> ""
         then abbreviate diagnostic
         else if String.trim stdout <> ""
         then abbreviate stdout
         else Printf.sprintf "exit %d with no output" status)
  ; verdict = classify_lookup recipe lookup
  }
;;

(* A kind this module can query, whose captured identity turned out not to carry
   what the recipe needs. That is UNKNOWN -- we intended to verify and could not
   -- and never absence. Distinct from [unqueried], where no lookup exists at all
   and the state postcondition is the only claim being made. *)
let unqueryable identity ~reason =
  { identity
  ; operation = "(no provider lookup could be built)"
  ; status = None
  ; evidence = reason
  ; verdict = Unknown reason
  }
;;

(* ── The Terraform-state postcondition ───────────────────────────────────────

   Independent of the provider answers and of `terraform destroy`'s exit status.
   The intended postcondition is "no target-owned disposable resource remains
   represented in this root". The root is pinned by the caller: DEC-043's durable
   GCP prerequisites live in `cli/platform/infra/bootstrap-gcp`, a different
   root, so they are not residue and are never asserted about here. *)

type state_evidence =
  | State_absent (* the read succeeded and this root represents nothing *)
  | State_residue of string list (* the read succeeded and these addresses remain *)
  | State_unreadable of string (* the read failed, or the document was malformed *)

let state_evidence = function
  | Ok [] -> State_absent
  | Ok addresses -> State_residue addresses
  | Error reason -> State_unreadable reason
;;

(* ── The demoted orphan sweep ────────────────────────────────────────────────

   The name/tag-derived checks that used to *be* the verification (EIPs, NAT
   gateways, EBS volumes, load balancers, ECR prefixes, the service-networking
   peering, ...). They still catch resources created indirectly by the VPC/EKS
   modules and by Kubernetes, which Terraform's state cannot speak for
   (INFRA-047) -- but they are secondary now: a residue is a violation, and an
   indeterminate check is reported and never converted into absence, because it
   cannot override the captured identities' evidence either way. *)

type sweep =
  | Sweep_not_run
  | Sweep_ran of
      { residues : string list
        (* positive findings: something attributable to this target is still there *)
      ; indeterminate : string list
        (* checks that could not establish anything (a failed query, a cannot
             reconstruct the name): reported, never read as absence *)
      }

(* ── Retention, observed rather than printed ───────────────────────────────── *)

type retention =
  | Retention_required_and_observed of string
    (* the target declared a retention guarantee and the provider was observed
         to hold it *)
  | Retention_not_required of string
    (* there was no retention promise to observe, and why *)
  | Retention_violated of string
  | Retention_unknown of string

(* The retention evidence, classified and abbreviated -- for diagnostics and test
   failures rather than for the operator-facing report, which prints the sentence
   itself. *)
let retention_to_string = function
  | Retention_required_and_observed evidence -> "observed: " ^ evidence
  | Retention_not_required reason -> "not required: " ^ reason
  | Retention_violated reason -> "violated: " ^ reason
  | Retention_unknown reason -> "unknown: " ^ reason
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

(* ── Combining the evidence, without voting ──────────────────────────────────

   Every source keeps its own voice. [violations] are postconditions with
   positive evidence against them; [unknowns] are required observations that could
   not be obtained. Both are failure ([is_verified] demands both be empty), but
   they are *not* the same claim, and neither is a degraded success: exit 3 means
   "the primary destruction postcondition succeeded but a preparation degraded",
   and an unestablished postcondition is not that. *)

type observation =
  { state : state_evidence
  ; identities : provider_observation list
  ; unqueried : (identity * string) list
    (* represented before destruction, with no provider lookup defined for the
         kind, and why: their absence rests on [state] alone, and saying so -- with
         the reason -- is the point *)
  ; sweep : sweep
  ; retention : retention
  }

type verdict =
  { violations : string list
  ; unknowns : string list
  }

let is_verified verdict = verdict.violations = [] && verdict.unknowns = []

let verdict_message verdict =
  let join = String.concat "; " in
  match verdict.violations, verdict.unknowns with
  | [], [] -> "the destruction postcondition is established"
  | violations, [] ->
    Printf.sprintf "the destruction postcondition is violated: %s" (join violations)
  | [], unknowns ->
    Printf.sprintf
      "the destruction postcondition could not be established (UNKNOWN is not absence): \
       %s"
      (join unknowns)
  | violations, unknowns ->
    Printf.sprintf
      "the destruction postcondition is violated (%s), and could not be established for \
       (%s)"
      (join violations)
      (join unknowns)
;;

let classify observation =
  let violations = ref [] in
  let unknowns = ref [] in
  let violate message = violations := message :: !violations in
  let unknown message = unknowns := message :: !unknowns in
  (match observation.state with
   | State_absent -> ()
   | State_residue addresses ->
     List.iter
       (fun address ->
          violate
            (Printf.sprintf
               "Terraform still represents %s in this root's state after destroy"
               address))
       addresses
   | State_unreadable reason ->
     unknown
       (Printf.sprintf
          "this root's Terraform state could not be read after destroy (%s), so what it \
           still represents is unknown"
          reason));
  List.iter
    (fun provider ->
       match provider.verdict with
       | Present ->
         violate
           (Printf.sprintf
              "the provider still has %s (`%s`)"
              (identity_to_string provider.identity)
              provider.operation)
       | Absent -> ()
       | Unknown reason ->
         unknown
           (Printf.sprintf
              "could not establish that %s is gone (`%s`): %s"
              (identity_to_string provider.identity)
              provider.operation
              reason))
    observation.identities;
  (* Only a sweep's *residues* are violations. Its indeterminate checks are reported
     by [report] and are deliberately not promoted here: step 5 section 5 refuses to
     let an unestablished name-derived query decide the result. *)
  (match observation.sweep with
   | Sweep_not_run -> ()
   | Sweep_ran { residues; _ } -> List.iter violate residues);
  (match observation.retention with
   | Retention_required_and_observed _ | Retention_not_required _ -> ()
   | Retention_violated reason -> violate reason
   | Retention_unknown reason -> unknown reason);
  { violations = List.rev !violations; unknowns = List.rev !unknowns }
;;

(* ── Operator-facing diagnostics ─────────────────────────────────────────────

   Answers step 5 section 9: what was expected absent, the exact identity queried,
   the evidence returned and how it was classified, what Terraform state says, and
   which postcondition remains unproven or violated. *)

let verdict_label = function
  | Present -> "PRESENT"
  | Absent -> "ABSENT"
  | Unknown _ -> "UNKNOWN"
;;

let report observation =
  let buffer = Buffer.create 1024 in
  let line format = Printf.ksprintf (Buffer.add_string buffer) format in
  line "  verification: evidence, not `terraform destroy`'s exit status\n";
  (match observation.state with
   | State_absent ->
     line
       "    terraform state (disposable root): no target-owned resource remains \
        represented\n"
   | State_residue addresses ->
     line
       "    terraform state (disposable root): STILL REPRESENTS %s\n"
       (String.concat ", " addresses)
   | State_unreadable reason ->
     line
       "    terraform state (disposable root): UNKNOWN -- the read failed (%s), which is \
        not absence\n"
       reason);
  if observation.identities = []
  then line "    captured identities: none were represented before destruction\n"
  else (
    line "    captured identities -- observed before destruction, queried after:\n";
    List.iter
      (fun provider ->
         line
           "      [%s] %s\n        queried:  %s\n        answered: %s\n"
           (verdict_label provider.verdict)
           (identity_to_string provider.identity)
           provider.operation
           provider.evidence)
      observation.identities);
  if observation.unqueried <> []
  then (
    line
      "    not provider-verified (%d): no provider lookup is defined for these kinds, so \
       their\n\
      \     absence rests on the Terraform state postcondition alone -- not on a \
       provider answer:\n"
      (List.length observation.unqueried);
    List.iter
      (fun (identity, reason) ->
         line "      %s\n        %s\n" (identity_to_string identity) reason)
      observation.unqueried);
  (match observation.sweep with
   | Sweep_not_run -> ()
   | Sweep_ran { residues = []; indeterminate = [] } ->
     line "    orphan sweep (names derived from the target): found nothing remaining\n"
   | Sweep_ran { residues; indeterminate } ->
     List.iter (fun reason -> line "    orphan sweep: %s\n" reason) residues;
     List.iter
       (fun reason ->
          line
            "    orphan sweep: inconclusive -- %s (reported, never read as absence)\n"
            reason)
       indeterminate);
  (match observation.retention with
   | Retention_required_and_observed evidence -> line "    retention: %s\n" evidence
   | Retention_not_required reason -> line "    retention: %s\n" reason
   | Retention_violated reason -> line "    retention: %s\n" reason
   | Retention_unknown reason -> line "    retention: %s\n" reason);
  Buffer.contents buffer
;;
