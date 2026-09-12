(* YAML manifest rendering and apply logic shared by sol up and sol deploy. *)

(* Re-export all YAML generators and service model types. *)
include Sol_cli_manifest_yaml

(* ── Secret backend type ─────────────────────────────────────────────────── *)

type secret_backend =
  | Kubernetes_live
  (** Emit a Kubernetes Secret with real values (live deploy / sol up). *)
  | Kubernetes_placeholder
  (** Emit a redacted Kubernetes Secret with empty stringData (GitOps). *)
  | External_secrets of
      { store_ref : string
      ; store_kind : string
      ; key_prefix : string
      ; refresh_interval : string
      }

let secret_backend_to_string = function
  | Kubernetes_live -> "kubernetes-live"
  | Kubernetes_placeholder -> "kubernetes-placeholder"
  | External_secrets _ -> "external-secrets"
;;

(* ── Service discovery ───────────────────────────────────────────────────── *)

let primitive_of_suffix name =
  if String.ends_with ~suffix:"_svc" name
  then Some Svc
  else if String.ends_with ~suffix:"_worker" name
  then Some Worker
  else if String.ends_with ~suffix:"_fn" name
  then Some Fn
  else None
;;

type discover_error = Missing_app_dir

let discover_error_to_string = function
  | Missing_app_dir -> "'app/' not found — run from the workspace root."
;;

(* CODE_LAYER-019: one scan produces typed workspace facts instead of each
   caller re-walking `app/<domain>/...` with its own suffix/Dockerfile rules.
   A workload fact exists for every directory that looks like a Sol primitive,
   even when its Dockerfile is missing — `sol check` needs those to report the
   missing file. Unexpected directories are captured as warnings instead of
   disappearing silently.
   Records are avoided for these facts because they would duplicate the field
   labels already used by [service] in this module and make every existing
   qualified record access ambiguous. *)

(** [workload_fact] is a [service] plus whether it has a Dockerfile. *)
type workload_fact = service * bool

(** [unexpected] is [(domain, name, dir)] for directories that do not match a
    Sol workload suffix. *)
type unexpected = string * string * string

type workspace_scan =
  { workloads : workload_fact list
  ; unexpected : unexpected list
  }

let workload_fact_to_service ((svc, _) : workload_fact) : service = svc
let has_dockerfile dir = Sys.file_exists (Filename.concat dir "Dockerfile")

(* Discovery answers "what is on disk", never "what did the user ask for".
   Selection happens once, after discovery, in [Sol_cli_workload_selection]
   (FEAT-065): a scan that took a filter could return a subset that looked
   identical to an empty workspace, which is exactly the confusion the strict
   selector removes. *)
let scan_workspace () =
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir)
  then Error Missing_app_dir
  else (
    let workloads = ref [] in
    let unexpected = ref [] in
    Array.iter
      (fun domain ->
         let dp = Filename.concat app_dir domain in
         if domain.[0] <> '.' && Sys.is_directory dp
         then
           Array.iter
             (fun name ->
                let dir = Filename.concat dp name in
                if name.[0] <> '.' && Sys.is_directory dir
                then (
                  match primitive_of_suffix name with
                  | Some primitive ->
                    let svc = { domain; name; primitive; dir } in
                    workloads := (svc, has_dockerfile dir) :: !workloads
                  | None -> unexpected := (domain, name, dir) :: !unexpected))
             (Sys.readdir dp))
      (Sys.readdir app_dir);
    Ok { workloads = List.rev !workloads; unexpected = List.rev !unexpected })
;;

let discover_services_result () =
  match scan_workspace () with
  | Error _ as err -> err
  | Ok scan ->
    Ok
      (scan.workloads
       |> List.filter_map (fun (svc, has_dockerfile) ->
         if has_dockerfile then Some svc else None))
;;

let discover_services () =
  match discover_services_result () with
  | Ok services -> services
  | Error err ->
    Printf.eprintf "error: %s\n" (discover_error_to_string err);
    exit 1
;;

(* ── Apply / emit helpers ────────────────────────────────────────────────── *)

exception Deploy_failed of string

let write_tmp content =
  let tmp = Filename.temp_file "sol-manifest-" ".yaml" in
  let oc = open_out tmp in
  output_string oc content;
  close_out oc;
  tmp
;;

let kubectl_apply tmp =
  match Sol_cli_kubectl.apply ~file:tmp with
  | Ok () -> ()
  | Error e ->
    raise (Deploy_failed ("kubectl apply failed: " ^ Sol_cli_process.error_to_string e))
;;

let apply_live yaml =
  let tmp = write_tmp yaml in
  (try kubectl_apply tmp with
   | e ->
     (try Sys.remove tmp with
      | _ -> ());
     raise e);
  Sys.remove tmp
;;

let apply (ns_yaml, workload_yaml) ~dry_run =
  if dry_run
  then Printf.printf "%s\n%s\n" ns_yaml workload_yaml
  else (
    apply_live ns_yaml;
    let tmp = write_tmp workload_yaml in
    (try
       (match Sol_cli_kubectl.apply_dry_run ~file:tmp with
        | Ok () -> ()
        | Error e ->
          raise
            (Deploy_failed
               ("kubectl server-side dry-run failed: " ^ Sol_cli_process.error_to_string e)));
       kubectl_apply tmp
     with
     | e ->
       (try Sys.remove tmp with
        | _ -> ());
       raise e);
    Sys.remove tmp)
;;

(* Write YAML for one service to <dir>/<ns>-<name>.yaml.
   Used by sol deploy --emit-to for GitOps workflows. *)
let emit_to_dir dir (ns_yaml, workload_yaml) ~ns ~name =
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir (Printf.sprintf "%s-%s.yaml" ns name) in
  let oc = open_out path in
  output_string oc ns_yaml;
  output_string oc "\n";
  output_string oc workload_yaml;
  output_string oc "\n";
  close_out oc;
  path
;;
