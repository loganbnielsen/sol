let reserved_platform_namespaces =
  [ "cert-manager"; "ingress-nginx"; "argocd"; "redpanda"; "monitoring"; "postgresql" ]
;;

let namespaces (plan : Sol_cli_deployment_plan.t) : string list =
  plan.services
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Sol_cli_deployment_plan.namespace_to_string spec.namespace)
  |> List.sort_uniq String.compare
;;

let value_from_env key =
  match Sys.getenv_opt key with
  | Some value -> value
  | None -> ""
;;

let secret_docs ?(secrets = Sol_cli_manifest.default_secrets) namespaces =
  let missing =
    secrets
    |> List.filter_map (fun (key, _) ->
      match Sys.getenv_opt key with
      | Some _ -> None
      | None -> Some key)
  in
  match missing with
  | first :: _ ->
    Error
      (Printf.sprintf
         "required secret env var(s) not set: %s. The workspace substrate (its runtime \
          Secret) cannot be established without them, and every workspace-scoped \
          operation -- migrations included -- needs it."
         first)
  | [] ->
    Ok
      (namespaces
       |> List.map (fun ns ->
         Sol_cli_manifest.secret_doc
           ~base_secrets:(List.map (fun (k, _) -> k, value_from_env k) secrets)
           ~ns
           ~name:Sol_cli_manifest.runtime_secret_name
           ()))
;;

let docs_for_namespaces ?secrets namespaces : (Sol_cli_yaml.document list, string) result =
  match secret_docs ?secrets namespaces with
  | Error _ as e -> e
  | Ok secret_docs ->
    Ok
      (List.map (fun ns -> Sol_cli_manifest.namespace_doc ~ns) namespaces
       @ List.map (fun ns -> Sol_cli_manifest.deploy_role_binding_doc ~ns) namespaces
       @ List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns) namespaces
       @ secret_docs)
;;

let docs ?secrets (plan : Sol_cli_deployment_plan.t)
  : (Sol_cli_yaml.document list, string) result
  =
  docs_for_namespaces ?secrets (namespaces plan)
;;

let create_idempotent = Sol_cli_manifest.create_idempotent

let with_doc_file doc f =
  Sol_cli_fs.with_temp_file
    ~prefix:"sol-substrate-"
    ~suffix:".yaml"
    (Sol_cli_yaml.render [ doc ])
    f
  |> Result.map_error (fun message -> Sol_cli_process.Spawn_failed message)
  |> Result.join
;;

let create_doc ~ctx doc = with_doc_file doc (fun file -> create_idempotent ~ctx ~file)

let create_failure e =
  "kubectl create (workspace substrate): " ^ Sol_cli_process.error_to_string e
;;

let apply_doc ~ctx doc =
  with_doc_file doc (fun file -> Sol_cli_kubectl.apply ~ctx ~file)
  |> Result.map_error (fun err ->
    Printf.sprintf
      "kubectl apply (workspace substrate): %s"
      (Sol_cli_process.error_to_string err))
;;

let ensure ~ctx ~namespaces : (unit, string) result =
  let open Result.Syntax in
  match List.find_opt (fun ns -> List.mem ns reserved_platform_namespaces) namespaces with
  | Some ns ->
    Error
      (Printf.sprintf
         "%s is a reserved platform namespace; no workspace may deploy into it"
         ns)
  | None ->
    let rec create_all = function
      | [] -> Ok ()
      | doc :: rest ->
        let* () = create_doc ~ctx doc |> Result.map_error create_failure in
        create_all rest
    in
    let rec apply_all = function
      | [] -> Ok ()
      | doc :: rest ->
        let* () = apply_doc ~ctx doc in
        apply_all rest
    in
    let* () =
      create_all (List.map (fun ns -> Sol_cli_manifest.namespace_doc ~ns) namespaces)
    in
    let* () =
      create_all
        (List.map (fun ns -> Sol_cli_manifest.deploy_role_binding_doc ~ns) namespaces
         @ List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns) namespaces
        )
    in
    (match secret_docs namespaces with
     | Error _ as e -> e
     | Ok docs -> apply_all docs)
;;

let operator_binding_docs ~workspace (services : Sol_cli_manifest.service list)
  : Sol_cli_yaml.document list
  =
  services
  |> List.filter_map (fun s ->
    match
      Sol_cli_deployment_plan.namespace_result
        ~workspace
        ~domain:s.Sol_cli_manifest.domain
    with
    | Ok ns -> Some (Sol_cli_deployment_plan.namespace_to_string ns)
    | Error _ -> None)
  |> List.sort_uniq String.compare
  |> List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns)
;;

let reconcile_operator_bindings ~ctx ~workspace ~services : (unit, string) result =
  let namespaces =
    services
    |> List.filter_map (fun s ->
      match
        Sol_cli_deployment_plan.namespace_result
          ~workspace
          ~domain:s.Sol_cli_manifest.domain
      with
      | Ok ns -> Some (Sol_cli_deployment_plan.namespace_to_string ns)
      | Error _ -> None)
    |> List.sort_uniq String.compare
  in
  let failures =
    namespaces
    |> List.filter_map (fun ns ->
      match create_doc ~ctx (Sol_cli_manifest.operator_role_binding_doc ~ns) with
      | Ok () -> None
      | Error e when Sol_cli_kubectl.classify e = Not_found -> None
      | Error e -> Some (Printf.sprintf "%s: %s" ns (create_failure e)))
  in
  match failures with
  | [] -> Ok ()
  | failures -> Error (String.concat "; " failures)
;;
