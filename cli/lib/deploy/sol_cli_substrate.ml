let reserved_platform_namespaces =
  [ "cert-manager"; "ingress-nginx"; "argocd"; "redpanda"; "monitoring"; "postgresql" ]
;;

let namespaces (plan : Sol_cli_deployment_plan.t) : string list =
  plan.services
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Sol_cli_deployment_plan.namespace_to_string spec.namespace)
  |> List.sort_uniq String.compare
;;

let docs_for_namespaces namespaces : Sol_cli_yaml.document list =
  List.map (fun ns -> Sol_cli_manifest.namespace_doc ~ns) namespaces
  @ List.map (fun ns -> Sol_cli_manifest.deploy_role_binding_doc ~ns) namespaces
  @ List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns) namespaces
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

let platform_network_fact ~ctx =
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:"configmap"
      ~name:"sol-platform-network"
      ~namespace:"kube-system"
      ~output:"json"
  with
  | Error _ -> None
  | Ok result ->
    (match Yojson.Safe.from_string result.Sol_cli_process.stdout with
     | `Assoc fields ->
       let data key =
         match List.assoc_opt "data" fields with
         | Some (`Assoc entries) ->
           (match List.assoc_opt key entries with
            | Some (`String value) -> Some value
            | _ -> None)
         | _ -> None
       in
       let cidrs =
         match data "database-egress-cidrs" with
         | Some text -> String.split_on_char ',' text |> List.filter (fun c -> c <> "")
         | None -> []
       in
       let port =
         match data "database-port" with
         | Some text ->
           (match int_of_string_opt text with
            | Some port -> port
            | None -> 5432)
         | None -> 5432
       in
       if cidrs = [] then None else Some (cidrs, port)
     | _ -> None
     | exception Yojson.Json_error _ -> None)
;;

let ensure ~workloads ~ctx ~namespaces : (unit, string) result =
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
    let* () =
      match platform_network_fact ~ctx with
      | None -> Ok ()
      | Some (cidrs, port) ->
        apply_all
          (List.map
             (fun (ns, name) ->
                Sol_cli_manifest.managed_database_egress_doc ~cidrs ~port ~ns ~name)
             workloads)
    in
    namespaces
    |> List.find_map (fun ns ->
      match Sol_cli_secret.verify_runtime_secret ~ctx ~namespace:ns with
      | Ok () -> None
      | Error message -> Some message)
    |> (function
     | None -> Ok ()
     | Some message -> Error message)
;;

let established ~ctx ~namespaces : (unit, string) result =
  let open Result.Syntax in
  let check_ns ns =
    match
      Sol_cli_kubectl.get ~ctx ~resource:"namespace" ~name:ns ~namespace:"" ~output:"name"
    with
    | Ok _ -> Ok ()
    | Error _ ->
      Error
        (Printf.sprintf
           "namespace %s does not exist, so the deploy identity holds no scoped \
            authority in it; Sol establishes a namespace and its scoped RBAC together, \
            and neither is present here"
           ns)
  in
  let check_binding ns name =
    match
      Sol_cli_kubectl.get ~ctx ~resource:"rolebinding" ~name ~namespace:ns ~output:"name"
    with
    | Ok _ -> Ok ()
    | Error _ ->
      Error
        (Printf.sprintf
           "namespace %s exists but has no %s RoleBinding, so any manifest operation \
            there would be refused before it began; deploy into %s with a live run, \
            which establishes the namespace and its scoped RBAC before it touches a \
            manifest"
           ns
           name
           ns)
  in
  let rec check = function
    | [] -> Ok ()
    | ns :: rest ->
      let* () = check_ns ns in
      let* () =
        List.fold_left
          (fun acc name -> Result.bind acc (fun () -> check_binding ns name))
          (Ok ())
          [ "sol-deploy"; "sol-operator" ]
      in
      check rest
  in
  check namespaces
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
