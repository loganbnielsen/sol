(* The release record (DEC-018, FEAT-067; content-addressed by FEAT-069).

   A release record describes *what is running* — the resolved released state —
   and is named by the content-addressed release id (FEAT-069). Two deploys of
   identical content are one release with one record; the invocation is a
   deployment event (FEAT-070), whose provenance deliberately does not appear
   here, because a timestamp or commit in the artifact would churn the GitOps
   diff for an unchanged release.

   The record body is the content the id is derived from, so a reader can
   recompute the id from the record rather than trust its name (see [validate]).
   It never stores secret *values*; only the secret references a workload uses.
   Config values are part of released state and are stored, because the id is
   derived from them. *)

(* BUG-026: the record's workload *is* the identity's workload. Keeping two
   hand-mirrored records in step is what let the projection drift; the record is
   the serialized artifact, so it shares the type and projects through
   [Sol_cli_deployment_plan.release_workload_of_spec]. *)
type workload = Sol_cli_release_id.workload

(* FEAT-066: how this release was applied/owned, so a later rollback can refuse
   to direct-mutate resources a controller owns. This is *historical per-release
   truth*, not present-day target config: a target can switch between direct and
   GitOps over its lifetime, so consulting today's config would misclassify an
   older release. Like [migrations], it is deliberately excluded from the
   content-addressed identity: the same desired workload applied directly or
   emitted for GitOps is one release with one id, but carries different
   ownership semantics -- so it lives in the body and is protected by the record
   digest below, rather than entering [release_id]. *)
type apply_mode =
  | Direct
  | Gitops

let apply_mode_to_string = function
  | Direct -> "direct"
  | Gitops -> "gitops"
;;

let apply_mode_of_string = function
  | "direct" -> Ok Direct
  | "gitops" -> Ok Gitops
  | s ->
    Error
      (Printf.sprintf
         "%S is not a valid apply_mode (expected \"direct\" or \"gitops\")"
         s)
;;

(* FEAT-066: which migration files existed at deploy time, so a later rollback
   can tell which migrations are *new since this release* and check their
   disposition. Deliberately not part of [Sol_cli_release_id.content]/the
   content-addressed identity: unlike a workload field, a migration file
   appearing on disk does not change what is *running* (it renders no
   manifest), so it must not change [release_id] and force a rollout that
   substantively changed nothing. It is still recorded in the body -- and
   still authoritative for the migration boundary check -- because the
   identity and the record body answer different questions ("is this the same
   running state" vs "what do we know happened by this point"). *)
type t =
  { release_id : string
  ; workspace : string
  ; environment : string option
  ; workloads : workload list
  ; migrations : string list
  ; apply_mode : apply_mode
  }

(* Label/annotation *values* are constrained (<=63 chars, no '/'); the exact
   text is preserved in the record body, this is only for lookup. *)
let sanitize_label (s : string) : string =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
       match c with
       | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> Buffer.add_char buf c
       | 'A' .. 'Z' -> Buffer.add_char buf (Char.lowercase_ascii c)
       | _ -> Buffer.add_char buf '-')
    s;
  let out = Buffer.contents buf in
  let out = if String.length out > 63 then String.sub out 0 63 else out in
  (* Trim leading/trailing separators so the label stays valid. *)
  let len = String.length out in
  let start = ref 0 in
  while
    !start < len && (out.[!start] = '-' || out.[!start] = '.' || out.[!start] = '_')
  do
    incr start
  done;
  let stop = ref (len - 1) in
  while
    !stop >= !start && (out.[!stop] = '-' || out.[!stop] = '.' || out.[!stop] = '_')
  do
    decr stop
  done;
  let trimmed =
    if !stop < !start then "" else String.sub out !start (!stop - !start + 1)
  in
  if trimmed = "" then "none" else trimmed
;;

let configmap_name (t : t) : string = Printf.sprintf "sol-release-%s" t.release_id

(* BUG-025: the pointer's name embeds the workspace, so it must go through the
   *name* sanitizer (not the label one) — '_' is fine in a label value and not
   in an object name. The shared home is [Sol_cli_kubernetes_name]. *)
let current_configmap_name ~(workspace : string) : string =
  Printf.sprintf
    "sol-release-current-%s"
    (Sol_cli_kubernetes_name.sanitize_name workspace)
;;

(* ── building the canonical record ───────────────────────────────────────── *)

(* The projection is [Sol_cli_deployment_plan.release_workload_of_spec]: one
   definition, so [derived_release_id] on a record built here reproduces
   [plan.release_id] by construction rather than by two lists agreeing. *)
let workload_of_spec (spec : Sol_cli_deployment_plan.service_spec) : workload =
  Sol_cli_deployment_plan.release_workload_of_spec spec
;;

let of_plan ~(apply_mode : apply_mode) (plan : Sol_cli_deployment_plan.t) : t =
  { release_id = Sol_cli_release_id.to_string plan.release_id
  ; workspace = plan.workspace
  ; environment = plan.environment.Sol_cli_deployment_plan.env
  ; workloads = List.map workload_of_spec plan.services
  ; migrations = List.map Sol_cli_plan_ids.Migration_file.to_string plan.migrations
  ; apply_mode
  }
;;

let content_of_record (t : t) : Sol_cli_release_id.content =
  { workspace = t.workspace; environment = t.environment; workloads = t.workloads }
;;

let derived_release_id (t : t) : Sol_cli_release_id.t =
  Sol_cli_release_id.of_content (content_of_record t)
;;

let validate ~(name : string) (t : t) : (unit, string) result =
  match Sol_cli_release_id.of_string t.release_id with
  | Error msg -> Error msg
  | Ok id ->
    if not (String.equal name (configmap_name t))
    then
      Error
        (Printf.sprintf
           "%s is not the record for release %s (expected name %s)"
           name
           t.release_id
           (configmap_name t))
    else (
      let derived = derived_release_id t in
      if derived <> id
      then
        Error
          (Printf.sprintf
             "release record %s is corrupt: its content rederives %s"
             t.release_id
             (Sol_cli_release_id.to_string derived))
      else Ok ())
;;

(* ── JSON ─────────────────────────────────────────────────────────────────── *)

(* Ordering is not semantic: sort every map-like list so the same content
   serializes to the same bytes, which is what makes the bundle idempotent *and*
   what makes the record digest a function of the record rather than of the order
   the caller happened to build its maps in.

   The order is total (key, then value): key alone is not a total order, so two
   entries with the same key would fall back on [List.sort]'s stability, which
   OCaml does not guarantee -- a canonical form must not depend on that. *)
let sorted_pairs pairs =
  List.sort
    (fun (a, av) (b, bv) ->
       let by_key = String.compare a b in
       if by_key <> 0 then by_key else String.compare av bv)
    pairs
;;

let pairs_to_assoc pairs =
  `Assoc (List.map (fun (k, v) -> k, `String v) (sorted_pairs pairs))
;;

let compare_workload (a : workload) (b : workload) =
  let by_domain = String.compare a.domain b.domain in
  if by_domain <> 0
  then by_domain
  else (
    let by_name = String.compare a.name b.name in
    if by_name <> 0 then by_name else String.compare a.primitive b.primitive)
;;

(* Row tables (volumes, calls) are sets, so sort rows by the whole tuple: two
   projections that differ only in source order must serialize to the same
   bytes, or a record with the same id would churn the GitOps diff. *)
let compare_row4 (a1, a2, a3, a4) (b1, b2, b3, b4) =
  let c = String.compare a1 b1 in
  if c <> 0
  then c
  else (
    let c = String.compare a2 b2 in
    if c <> 0
    then c
    else (
      let c = String.compare a3 b3 in
      if c <> 0 then c else String.compare a4 b4))
;;

let rows_to_json rows =
  `List
    (List.map
       (fun (a, b, c, d) -> `List [ `String a; `String b; `String c; `String d ])
       (List.sort compare_row4 rows))
;;

let workload_to_json (w : workload) : Yojson.Safe.t =
  `Assoc
    [ "domain", `String w.domain
    ; "name", `String w.name
    ; "primitive", `String w.primitive
    ; "image", `String w.image
    ; "config", pairs_to_assoc w.config
    ; "secrets", pairs_to_assoc w.secrets
    ; ( "schedule"
      , match w.schedule with
        | None -> `Null
        | Some s -> `String s )
    ; "replicas", `Int w.replicas
    ; "availability", `String w.availability
    ; "consumes_kafka", `Bool w.consumes_kafka
    ; "cpu", `String w.cpu
    ; "memory", `String w.memory
    ; "extra_labels", pairs_to_assoc w.extra_labels
    ; "volumes", rows_to_json w.volumes
    ; "rollout", `String w.rollout
    ; ( "ingress_host"
      , match w.ingress_host with
        | None -> `Null
        | Some h -> `String h )
    ; ( "ingress_path"
      , match w.ingress_path with
        | None -> `Null
        | Some p -> `String p )
    ; "cluster_issuer", `String w.cluster_issuer
    ; "calls", rows_to_json w.calls
    ]
;;

let to_json (t : t) : Yojson.Safe.t =
  `Assoc
    [ "release_id", `String t.release_id
    ; "workspace", `String t.workspace
    ; ( "environment"
      , match t.environment with
        | None -> `Null
        | Some e -> `String e )
    ; ( "workloads"
      , `List (List.map workload_to_json (List.sort compare_workload t.workloads)) )
    ; ( "migrations"
      , `List (List.map (fun m -> `String m) (List.sort String.compare t.migrations)) )
    ; "apply_mode", `String (apply_mode_to_string t.apply_mode)
    ]
;;

(* FEAT-066: the canonical serialization of the complete record -- the single
   representation the digest is defined over. Its stability is what the digest
   means, so the rules are deliberate and pinned by
   [test_release.test_record_digest_known_vector]:

   - object members are written in a fixed order ([to_json]'s field order), never
     the order a caller built its records in;
   - every set/map-like list is sorted to a total order before writing: workloads
     by (domain, name, primitive), [config]/[secrets]/[extra_labels] by
     (key, value), [volumes]/[calls] rows by the whole tuple, [migrations] by
     name;
   - [Yojson.Safe.to_string] then emits that tree compactly.

   This is the exact string stored in the ConfigMap's [data.record] and in a
   GitOps bundle, so hashing it covers every persisted field -- including the
   non-identity ones ([migrations], [apply_mode]) that [release_id] cannot
   protect, because they are deliberately outside the content-addressed
   identity.

   Deliberately *not* built on {!Sol_cli_release_id.canonical_string}: that
   encoding is a versioned contract of the *identity* and its own mli says it
   may change with [encoding_version]. A digest defined over it would become
   unverifiable for already-written records the moment the identity encoding
   changed. Keeping the digest over this representation, and verifying it
   byte-for-byte on read (never re-encoding), means a record written today stays
   verifiable however [to_json] or the JSON serializer evolves later. *)
let record_json_string (t : t) : string = Yojson.Safe.to_string (to_json t)

(* A free digest the store records alongside the body and rechecks on read.
   [release_id] proves the record's *content* is internally consistent; this
   proves the *stored bytes* have not changed since they were written, so a
   record whose body was altered (e.g. an inflated [migrations] list that would
   silently defeat the migration boundary check) fails closed instead of being
   read as trustworthy.

   [record_digest] is a pure function of [record_json_string], so the write side
   and any independent re-computation agree; the read side ({!of_kubectl_item})
   instead hashes the stored bytes directly, so verification never depends on
   re-serializing an existing record.

   This is an integrity check, not a signature: it detects corruption and
   inconsistent/partial writes, and makes the non-identity fields as
   tamper-evident as the id. It does not defend against an actor who can rewrite
   the whole ConfigMap, including the digest -- nothing stored in the record can,
   since the digest is not keyed. *)
let record_digest (t : t) : string = Digest.to_hex (Digest.string (record_json_string t))

(* Safe accessors: a malformed cluster object must not crash a read-only list. *)
let mem key = function
  | `Assoc kvs -> List.assoc_opt key kvs
  | _ -> None
;;

let str key json =
  match mem key json with
  | Some (`String s) -> s
  | _ -> ""
;;

let int key json =
  match mem key json with
  | Some (`Int i) -> i
  | _ -> 0
;;

let list key json =
  match mem key json with
  | Some (`List l) -> l
  | _ -> []
;;

let string_option key json =
  match mem key json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let pairs key json =
  match mem key json with
  | Some (`Assoc kvs) ->
    List.map
      (fun (k, v) ->
         ( k
         , match v with
           | `String s -> s
           | _ -> "" ))
      kvs
  | _ -> []
;;

let rows key json =
  match mem key json with
  | Some (`List rows) ->
    List.map
      (function
        | `List cells ->
          List.map
            (function
              | `String s -> s
              | _ -> "")
            cells
        | _ -> [])
      rows
  | _ -> []
;;

(* A malformed row becomes an empty one, exactly as [str] yields [""]; the record
   still fails closed in [validate] because its id stops rederiving. *)
let row4 = function
  | [ a; b; c; d ] -> a, b, c, d
  | _ -> "", "", "", ""
;;

let workload_of_json (json : Yojson.Safe.t) : workload =
  { domain = str "domain" json
  ; name = str "name" json
  ; primitive = str "primitive" json
  ; image = str "image" json
  ; config = pairs "config" json
  ; secrets = pairs "secrets" json
  ; schedule = string_option "schedule" json
  ; replicas = int "replicas" json
  ; availability =
      (* Records written before AUDIT-080 have no availability; they were
         rendered as [single]. *)
      (match Yojson.Safe.Util.member "availability" json with
       | `String s -> s
       | _ -> "single")
  ; consumes_kafka =
      (* Records written before AUDIT-080 were rendered without consumer probes;
         a missing field means "not a declared consumer". *)
      (match Yojson.Safe.Util.member "consumes_kafka" json with
       | `Bool b -> b
       | _ -> false)
  ; cpu = str "cpu" json
  ; memory = str "memory" json
  ; extra_labels = pairs "extra_labels" json
  ; volumes = List.map row4 (rows "volumes" json)
  ; rollout = str "rollout" json
  ; ingress_host = string_option "ingress_host" json
  ; ingress_path = string_option "ingress_path" json
  ; cluster_issuer = str "cluster_issuer" json
  ; calls = List.map row4 (rows "calls" json)
  }
;;

let string_list key json =
  List.filter_map
    (function
      | `String s -> Some s
      | _ -> None)
    (list key json)
;;

(* FEAT-066: [apply_mode] is required and must be recognised. A missing or
   unknown value fails closed rather than being defaulted to [Direct] -- Sol
   cannot establish ownership it was never told, and guessing "direct" would
   re-open the exact false-ownership path this field exists to close. *)
let apply_mode_of_json (json : Yojson.Safe.t) : (apply_mode, string) result =
  match mem "apply_mode" json with
  | Some (`String s) -> apply_mode_of_string s
  | Some _ -> Error "release record has a non-string apply_mode"
  | None -> Error "release record is missing apply_mode"
;;

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match str "release_id" json, str "workspace" json with
  | "", _ | _, "" -> Error "release record is missing release_id/workspace"
  | release_id, workspace ->
    (match apply_mode_of_json json with
     | Error msg -> Error msg
     | Ok apply_mode ->
       Ok
         { release_id
         ; workspace
         ; environment = string_option "environment" json
         ; workloads = List.map workload_of_json (list "workloads" json)
         ; migrations = string_list "migrations" json
         ; apply_mode
         })
;;

(* ── Kubernetes objects ───────────────────────────────────────────────────── *)

(* Applied through kubectl, which accepts JSON as YAML. [immutable: true] is
   what makes the record a record: a second apply of the same content is a
   no-op, but editing it in place is rejected by the API server. *)
let to_configmap_json (t : t) : string =
  Yojson.Safe.pretty_to_string
    (`Assoc
        [ "apiVersion", `String "v1"
        ; "kind", `String "ConfigMap"
        ; "immutable", `Bool true
        ; ( "metadata"
          , `Assoc
              [ "name", `String (configmap_name t)
              ; "namespace", `String "default"
              ; ( "labels"
                , `Assoc
                    [ "sol.dev/type", `String "release"
                    ; "sol.dev/workspace", `String (sanitize_label t.workspace)
                    ] )
              ] )
        ; ( "data"
          , `Assoc
              [ "release_id", `String t.release_id
              ; "record", `String (record_json_string t)
              ; "record_digest", `String (record_digest t)
              ] )
        ])
;;

(* Mutable pointer: names the current release per workspace, so a later
   rollback can find "what is deployed" without scanning. Its payload is
   deliberately [release_id] only — the immutable record is the one
   authoritative description, and a second copy here could drift from it. *)
let to_current_configmap_json (t : t) : string =
  Yojson.Safe.pretty_to_string
    (`Assoc
        [ "apiVersion", `String "v1"
        ; "kind", `String "ConfigMap"
        ; ( "metadata"
          , `Assoc
              [ "name", `String (current_configmap_name ~workspace:t.workspace)
              ; "namespace", `String "default"
              ; ( "labels"
                , `Assoc
                    [ "sol.dev/type", `String "release-current"
                    ; "sol.dev/workspace", `String (sanitize_label t.workspace)
                    ] )
              ] )
        ; "data", `Assoc [ "release_id", `String t.release_id ]
        ])
;;

let bundle_files (t : t) : (string * string) list =
  [ configmap_name t ^ ".yaml", to_configmap_json t
  ; "sol-current-release.yaml", to_current_configmap_json t
  ]
;;

(* ── Reading back ─────────────────────────────────────────────────────────── *)

let item_name item =
  match mem "metadata" item with
  | Some metadata -> str "name" metadata
  | None -> ""
;;

(* FEAT-072: the release record deliberately carries no timestamp (FEAT-069), so
   retention orders records by the cluster-assigned [metadata.creationTimestamp]
   instead. It is object metadata, not part of the record body, so it stays out
   of [t]/[to_json]/[record_digest] and the content-addressed identity. *)
let creation_timestamp_of_item item =
  match mem "metadata" item with
  | Some metadata -> str "creationTimestamp" metadata
  | None -> ""
;;

(* One release ConfigMap ([kubectl get configmap ... -o json] on a single
   object, or one entry of a [-l ...] list's [items]) -> its record. Fails
   closed (FEAT-071): a record that is absent, unparseable, or does not
   [validate] is corruption and returns an [Error] naming it. Shared by
   {!parse_kubectl_list} and a single-release lookup (FEAT-066's rollback
   resolve step), so the two can never disagree about what makes a record
   valid. *)
let of_kubectl_item (item : Yojson.Safe.t) : (t, string) result =
  let name = item_name item in
  let label = if String.equal name "" then "<unnamed configmap>" else name in
  match mem "data" item with
  | None -> Error (Printf.sprintf "%s has no data" label)
  | Some data ->
    (match mem "record" data with
     | Some (`String record) ->
       (* FEAT-066: check the body's integrity before trusting *any* field,
          including the non-identity ones ([migrations], [apply_mode]) that
          [validate]'s id-rederivation cannot see. A missing digest is a
          schema/format problem (an old or hand-written object); a mismatched
          digest is corruption. Both fail closed, with distinct messages. *)
       (match mem "record_digest" data with
        | Some (`String stored) when String.length stored > 0 ->
          if not (String.equal (Digest.to_hex (Digest.string record)) stored)
          then Error (Printf.sprintf "%s failed integrity validation" label)
          else (
            match Yojson.Safe.from_string record with
            | exception _ -> Error (Printf.sprintf "%s: data.record is not JSON" label)
            | parsed ->
              (match of_json parsed with
               | Error msg -> Error (Printf.sprintf "%s: %s" label msg)
               | Ok r ->
                 (match validate ~name r with
                  | Error msg -> Error msg
                  | Ok () -> Ok r)))
        | _ ->
          Error
            (Printf.sprintf
               "%s uses an unsupported record format: missing integrity digest"
               label))
     | _ -> Error (Printf.sprintf "%s has no data.record" label))
;;

(* [kubectl get configmap -l ... -o json] -> the records it carries, each paired
   with its cluster [metadata.creationTimestamp] (FEAT-072 retention orders by
   it). Fails closed (FEAT-071): the store is authoritative release history, so a
   matching record that is absent, unparseable, or does not [validate] is
   corruption and returns an [Error] naming it — dropping it would print a
   partial list as if it were the whole one. *)
let parse_kubectl_list_with_creation (json : Yojson.Safe.t)
  : ((t * string) list, string) result
  =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      (match of_kubectl_item item with
       | Error msg ->
         Error (Printf.sprintf "release history contains an invalid record: %s" msg)
       | Ok r -> go ((r, creation_timestamp_of_item item) :: acc) rest)
  in
  go [] (list "items" json)
;;

let parse_kubectl_list json =
  parse_kubectl_list_with_creation json |> Result.map (List.map fst)
;;

let format_table (records : t list) : string =
  let sorted =
    List.sort (fun (a : t) (b : t) -> String.compare a.release_id b.release_id) records
  in
  let rows =
    List.map
      (fun (r : t) ->
         [ r.release_id
         ; (match r.environment with
            | None -> "-"
            | Some e -> e)
         ; string_of_int (List.length r.workloads)
         ])
      sorted
  in
  let headers = [ "ID"; "ENV"; "WORKLOADS" ] in
  let widths =
    List.mapi
      (fun i h ->
         List.fold_left
           (fun acc row -> max acc (String.length (List.nth row i)))
           (String.length h)
           rows)
      headers
  in
  let render_row row =
    List.mapi (fun i cell -> Printf.sprintf "%-*s" (List.nth widths i) cell) row
    |> String.concat "  "
    |> fun s -> String.trim s
  in
  String.concat "\n" (render_row headers :: List.map render_row rows)
;;

(* ── DEC-037: the deployment outcome ───────────────────────────────────────── *)

(* Recording the release is part of a deployment's outcome, not bookkeeping after
   it. The pointer written here is what `sol rollback` restores and what retention
   anchors on, so a deployment that cannot advance it has not succeeded -- and must
   not print a success line over a release state that still describes the previous
   release.

   Both `sol deploy` and `sol up` route through this, so the two cannot drift the
   way they did before: the order (record, then report) and the propagation (a
   record failure is the deployment's failure) are decided in one place. *)
let finish_deployment ~(record_release : unit -> (unit, string) result) ~report_success =
  match record_release () with
  | Error msg -> Error msg
  | Ok () ->
    report_success ();
    Ok ()
;;
