(* AUDIT-069: the migration prerequisite a production deploy verifies.

   The deployable revision defines the schema it expects: every migration in the
   workspace's [db/migrations] directory must already be applied before
   application code that assumes it rolls out. That is the whole contract --

     required (from db/migrations)  ⊆  applied (from schema_migrations)

   -- with no third piece of deployment metadata describing "which migrations
   matter". Adding one would let db/migrations, the deployment record and
   schema_migrations disagree about the schema, which is the duplicate authority
   this ticket exists to remove. The consequence, accepted deliberately: adding
   a file to [db/migrations] is a declaration that it is a prerequisite for
   deploying that revision.

   Nothing here talks to a database or a cluster: this module is the pure
   comparison and encoding, so the deploy path can be tested without one. *)

type prerequisite =
  { version : int
  ; name : string
  }

let default_dir = "db/migrations"

(* Same per-workspace naming as [sol migrate], so the deploy reads exactly the
   table [sol migrate apply] writes. Kept identical to
   cli/sol/bin/cmd_migrate.ml's [default_table_name]. *)
let table_name ~workspace =
  let buf = Buffer.create (String.length workspace) in
  String.iter
    (fun c ->
       if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
       then Buffer.add_char buf c
       else if c >= 'A' && c <= 'Z'
       then Buffer.add_char buf (Char.lowercase_ascii c)
       else Buffer.add_char buf '_')
    workspace;
  Printf.sprintf "sol_%s_schema_migrations" (Buffer.contents buf)
;;

(* [001_create_orders.sql] -> [(1, "create_orders")]. Requires the leading
   numeric version and an underscore separator, matching the migration-file
   convention [sol migrate] already applies in order. *)
let parse_version fname =
  let base = Filename.remove_extension fname in
  match String.index_opt base '_' with
  | None -> None
  | Some i ->
    let num = String.sub base 0 i in
    (match int_of_string_opt num with
     | Some version when version >= 0 ->
       Some (version, String.sub base (i + 1) (String.length base - i - 1))
     | _ -> None)
;;

(* Every migration in [dir], ordered by version. An unparsable file name is an
   error rather than a silent skip: a migration the deploy would not require is
   exactly the failure this check exists to prevent.

   BUG-041 / FND-0032: a migration's identity in [schema_migrations] -- and so in
   the runner's "pending" set -- is its version alone. Two files with one version
   would let the second be skipped forever once the first is applied, with this
   gate still reporting the version as applied. So a shared version is an error
   that names both files. Down files ([NNN_x.down.sql]) are the runner's rollback
   companions, not migrations, and are excluded exactly as the runner excludes them. *)
let duplicate_versions migrations =
  let rec scan acc = function
    | a :: (b :: _ as rest) when a.version = b.version -> scan ((a, b) :: acc) rest
    | _ :: rest -> scan acc rest
    | [] -> List.rev acc
  in
  scan [] (List.stable_sort (fun a b -> compare a.version b.version) migrations)
;;

let required ~dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> Ok []
  | arr ->
    let sql =
      Array.to_list arr
      |> List.filter (fun f ->
        Filename.check_suffix f ".sql" && not (Filename.check_suffix f ".down.sql"))
      |> List.sort String.compare
    in
    let rec parse acc = function
      | [] -> Ok (List.rev acc)
      | fname :: rest ->
        (match parse_version fname with
         | Some (version, name) -> parse ({ version; name } :: acc) rest
         | None ->
           Error
             (Printf.sprintf
                "migration file %S does not start with a numeric version separated by \
                 `_` (expected e.g. `001_create_orders.sql`)"
                (Filename.concat dir fname)))
    in
    (match parse [] sql with
     | Error _ as e -> e
     | Ok migrations ->
       (match duplicate_versions migrations with
        | [] -> Ok migrations
        | (a, b) :: _ ->
          Error
            (Printf.sprintf
               "migrations %s.sql and %s.sql in %s share version %d; each migration \
                needs                 its own version, or the runner applies one and \
                silently skips the other                 -- renumber one of them"
               (Printf.sprintf "%03d_%s" a.version a.name)
               (Printf.sprintf "%03d_%s" b.version b.name)
               dir
               a.version)))
;;

let to_string (p : prerequisite) = Printf.sprintf "%03d_%s" p.version p.name

(* The applied versions the migration runner reports, from
   [sol migrate status --json]. Only the versions are needed: the contract is
   "is this migration applied", and [applied_at] is presentation. *)
let parse_status_json text =
  let open Yojson.Safe.Util in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)
  | json ->
    (match member "migrations" json with
     | `List items ->
       let versions =
         List.filter_map
           (fun item ->
              match to_bool (member "applied" item) with
              | true ->
                (match to_int (member "version" item) with
                 | v -> Some v
                 | exception Type_error _ -> None)
              | false -> None
              | exception Type_error _ -> None)
           items
       in
       Ok versions
     | _ -> Error "missing \"migrations\" array")
;;

(* required \ applied -- the migrations the revision requires but the
   authoritative table does not have. *)
let unsatisfied ~required ~applied =
  List.filter (fun (p : prerequisite) -> not (List.mem p.version applied)) required
;;

(* The machine-readable status the deploy's read-only Job consumes. Emitted by
   [sol migrate status --json]; lives here so writer and reader share one
   encoding. *)
let status_json ~table rows =
  `Assoc
    [ "table", `String table
    ; ( "migrations"
      , `List
          (List.map
             (fun (version, name, applied_at) ->
                `Assoc
                  [ "version", `Int version
                  ; "name", `String name
                  ; "applied", `Bool (Option.is_some applied_at)
                  ; ( "applied_at"
                    , match applied_at with
                      | Some s -> `String s
                      | None -> `Null )
                  ])
             rows) )
    ]
  |> Yojson.Safe.to_string
;;

(* INFRA-040: the deploy's migration gate removes the Job it ran, so a failure
   has to be read *out* of the Job before that happens. This is the report the
   deploy prints: what the container was waiting on, if it never started, and
   whatever the Job logged, if it did.

   Kept pure and here rather than inline in the binary because "a Job that cannot
   start is reported with its reason" is exactly the property Attempt 6 needed
   and could not see, and the shell-out path around it is not testable offline.
   The caller gathers the two observations; this decides what the operator reads.
   Either half may be absent: a container that never started has no logs, and a
   Job that ran and failed has no waiting reason. *)
let evidence_report ~waiting ~logs =
  let waiting_lines =
    match waiting with
    | Some (reason, detail) when String.trim reason <> "" ->
      let detail = String.trim detail in
      [ Printf.sprintf
          "container waiting: %s%s"
          (String.trim reason)
          (if detail = "" then "" else " -- " ^ detail)
      ]
    | _ -> []
  in
  let logs = String.trim logs in
  let log_lines = if logs = "" then [] else [ "job logs:\n" ^ logs ] in
  String.concat "\n\n" (waiting_lines @ log_lines)
;;
