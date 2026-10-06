include Sol_cli_manifest_yaml
include Sol_cli_manifest_cluster_env

type secret_backend =
  | Kubernetes_live
  | Kubernetes_placeholder
  | External_secrets of
      { store_ref : string
      ; store_kind : secret_store_kind
      ; key_prefix : string
      ; refresh_interval : string
      }

let secret_backend_to_string = function
  | Kubernetes_live -> "kubernetes-live"
  | Kubernetes_placeholder -> "kubernetes-placeholder"
  | External_secrets _ -> "external-secrets"
;;

let primitive_of_suffix name =
  if String.ends_with ~suffix:"_svc" name
  then Some Svc
  else if String.ends_with ~suffix:"_worker" name
  then Some Worker
  else if String.ends_with ~suffix:"_fn" name
  then Some Fn
  else None
;;

type discover_error =
  | Missing_app_dir
  | Workspace_error of Sol_cli_workspace.workspace_error

let discover_error_to_string = function
  | Missing_app_dir -> "'app/' not found — run from the workspace root."
  | Workspace_error e -> Sol_cli_workspace.workspace_error_to_string e
;;

type workload_fact = service * bool
type unexpected = string * string * string

type workspace_scan =
  { workloads : workload_fact list
  ; unexpected : unexpected list
  }

let workload_fact_to_service ((svc, _) : workload_fact) : service = svc
let has_dockerfile dir = Sys.file_exists (Filename.concat dir "Dockerfile")

let scan_workspace ?root () =
  let resolved =
    match root with
    | Some root -> Ok root
    | None -> Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
  in
  match resolved with
  | Error e -> Error (Workspace_error e)
  | Ok root ->
    let app_dir = Filename.concat root "app" in
    if not (Sys.file_exists app_dir && Sys.is_directory app_dir)
    then Error Missing_app_dir
    else (
      let workloads = ref [] in
      let unexpected = ref [] in
      Sys.readdir app_dir
      |> Array.iter (fun domain ->
        let dp = Filename.concat app_dir domain in
        if domain.[0] <> '.' && Sys.is_directory dp
        then
          Sys.readdir dp
          |> Array.iter (fun name ->
            let full = Filename.concat dp name in
            if name.[0] <> '.' && Sys.is_directory full
            then (
              let dir = Filename.concat "app" (Filename.concat domain name) in
              match primitive_of_suffix name with
              | Some primitive ->
                let svc = { domain; name; primitive; dir } in
                workloads := (svc, has_dockerfile full) :: !workloads
              | None -> unexpected := (domain, name, dir) :: !unexpected)));
      Ok { workloads = List.rev !workloads; unexpected = List.rev !unexpected })
;;

let discover_services ?root () =
  match scan_workspace ?root () with
  | Error _ as err -> err
  | Ok scan ->
    Ok
      (scan.workloads
       |> List.filter_map (fun (svc, has_dockerfile) ->
         if has_dockerfile then Some svc else None))
;;

let create_idempotent ~ctx ~file =
  match Sol_cli_kubectl.create ~ctx ~file with
  | Ok _ -> Ok ()
  | Error e when Sol_cli_kubectl.classify e = Already_exists -> Ok ()
  | Error e -> Error e
;;

let with_manifest_file yaml f =
  Sol_cli_fs.with_temp_file ~prefix:"sol-manifest-" ~suffix:".yaml" yaml f
  |> Result.map_error (fun message -> Sol_cli_process.Spawn_failed message)
  |> Result.join
;;

let create_idempotent_yaml ~ctx yaml =
  with_manifest_file yaml (fun file -> create_idempotent ~ctx ~file)
;;

let apply ~ctx (ns_yaml, workload_yaml) ~dry_run =
  let open Result.Syntax in
  let step what = Result.map_error (fun e -> what ^ Sol_cli_process.error_to_string e) in
  if dry_run
  then (
    Sol_cli_report.app "%s\n%s" ns_yaml workload_yaml;
    Ok ())
  else
    let* () =
      create_idempotent_yaml ~ctx ns_yaml |> step "kubectl create (namespace): "
    in
    Sol_cli_fs.with_temp_file
      ~prefix:"sol-manifest-"
      ~suffix:".yaml"
      workload_yaml
      (fun file ->
         let* () =
           Sol_cli_kubectl.apply_dry_run ~ctx ~file
           |> step "kubectl server-side dry-run failed: "
         in
         Sol_cli_kubectl.apply ~ctx ~file |> step "kubectl apply failed: ")
    |> Result.join
;;

let emit_to_dir dir (ns_yaml, workload_yaml) ~ns ~name =
  let open Result.Syntax in
  let path = Filename.concat dir (Printf.sprintf "%s-%s.yaml" ns name) in
  let* () = Sol_cli_fs.mkdir_p dir in
  let* () = Sol_cli_fs.write_atomic path (ns_yaml ^ "\n" ^ workload_yaml ^ "\n") in
  Ok path
;;
