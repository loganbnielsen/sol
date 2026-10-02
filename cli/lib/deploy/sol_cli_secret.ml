type action_result =
  | Applied of string list
  | Deleted of string list
  | Listed of string list

open Result.Syntax

let is_key_char = function
  | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false
;;

let validate_key_format key =
  let len = String.length key in
  if len = 0
  then Error "secret key must not be empty"
  else if len > 253
  then Error "secret key must be 253 characters or fewer"
  else if not (key.[0] >= 'A' && key.[0] <= 'Z')
  then Error "secret key must start with an uppercase letter"
  else if not (String.for_all is_key_char key)
  then Error "secret key may contain only uppercase letters, digits, and underscores"
  else Ok ()
;;

let validate_key key =
  let* () = validate_key_format key in
  if String.equal key "SOL_ALLOW_UNVERIFIED_JWT"
  then
    Error
      "SOL_ALLOW_UNVERIFIED_JWT is reserved: it allows JWT auth without signature \
       checks, and `sol up` sets it on the local cluster only"
  else Ok ()
;;

type object_metadata =
  { name : string
  ; namespace : string
  }

type kubernetes_secret =
  { api_version : string
  ; kind : string
  ; metadata : object_metadata
  ; secret_type : string
  ; data : (string * string) list
  ; string_data : (string * string) list
  }

let render_secret_manifest secret =
  let quoted_map pairs =
    Sol_cli_yaml.map (List.map (fun (k, v) -> k, Sol_cli_yaml.quoted v) pairs)
  in
  let data =
    match secret.data with
    | [] -> []
    | pairs -> [ "data", quoted_map pairs ]
  in
  Sol_cli_yaml.(
    render
      [ document
          (map
             ([ "apiVersion", string secret.api_version
              ; "kind", string secret.kind
              ; ( "metadata"
                , map
                    [ "name", string secret.metadata.name
                    ; "namespace", string secret.metadata.namespace
                    ] )
              ; "type", string secret.secret_type
              ]
              @ data
              @ [ "stringData", quoted_map secret.string_data ]))
      ])
;;

let named_secret_manifest ~secret_name ~existing_data ~namespace ~key ~value =
  let data = List.filter (fun (k, _) -> k <> key) existing_data in
  render_secret_manifest
    { api_version = "v1"
    ; kind = "Secret"
    ; metadata = { name = secret_name; namespace }
    ; secret_type = "Opaque"
    ; data
    ; string_data = [ key, value ]
    }
;;

let secret_manifest ~existing_data ~namespace ~key ~value =
  named_secret_manifest
    ~secret_name:Sol_cli_manifest.runtime_secret_name
    ~existing_data
    ~namespace
    ~key
    ~value
;;

let redacted_result = function
  | Applied namespaces ->
    Printf.sprintf "secret set in %d namespace(s)" (List.length namespaces)
  | Deleted namespaces ->
    Printf.sprintf "secret deleted from %d namespace(s)" (List.length namespaces)
  | Listed keys -> String.concat "\n" keys
;;

let apply_manifest ~ctx yaml =
  Sol_cli_fs.with_temp_file ~prefix:"sol-secret-" ~suffix:".yaml" yaml (fun path ->
    Sol_cli_kubectl.apply ~ctx ~file:path
    |> Result.map_error Sol_cli_process.error_to_string)
  |> Result.join
;;

let ensure_namespace ~ctx namespace =
  Sol_cli_fs.with_temp_file
    ~prefix:"sol-secret-ns-"
    ~suffix:".yaml"
    (Sol_cli_yaml.render [ Sol_cli_manifest.namespace_doc ~ns:namespace ])
    (fun path ->
       Sol_cli_manifest.create_idempotent ~ctx ~file:path
       |> Result.map_error (fun e ->
         Printf.sprintf
           "could not ensure namespace %s: %s"
           namespace
           (Sol_cli_process.error_to_string e)))
  |> Result.join
;;

let get_named_secret_json ~ctx ~name namespace =
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:[ "get"; "secret"; name; "-n"; namespace; "-o"; "json" ]
  with
  | Ok None -> Ok None
  | Ok (Some json) ->
    Sol_cli_json.decode ~what:(Printf.sprintf "Secret %s/%s" namespace name) json
    |> Result.map Option.some
  | Error e ->
    Error
      (Printf.sprintf
         "could not read Secret %s/%s: %s"
         namespace
         name
         (Sol_cli_process.error_to_string e))
;;

let listed_names ~what (result : (Sol_cli_process.output, Sol_cli_process.error) result) =
  match result with
  | Ok r ->
    Ok
      (String.split_on_char '\n' r.stdout
       |> List.map String.trim
       |> List.filter (fun name -> name <> ""))
  | Error (Sol_cli_process.Non_zero r) ->
    Error
      (Printf.sprintf
         "could not list %s: %s"
         what
         (let detail = String.trim r.stderr in
          if detail = "" then Printf.sprintf "kubectl exited %d" r.exit_code else detail))
  | Error e ->
    Error
      (Printf.sprintf "could not list %s: %s" what (Sol_cli_process.error_to_string e))
;;

let get_secret_json ~ctx namespace =
  get_named_secret_json ~ctx ~name:Sol_cli_manifest.runtime_secret_name namespace
;;

let data_keys = function
  | `Assoc fields ->
    (match List.assoc_opt "data" fields with
     | Some (`Assoc data) -> data
     | _ -> [])
  | _ -> []
;;

let existing_data = function
  | None -> []
  | Some json ->
    List.filter_map
      (function
        | k, `String v -> Some (k, v)
        | _ -> None)
      (data_keys json)
;;

let list_workload_secrets ~ctx namespace =
  let jsonpath = "{range .items[*]}{.metadata.name}{\"\\n\"}{end}" in
  Sol_cli_kubectl.get_raw
    ~ctx
    ~args:[ "get"; "secrets"; "-n"; namespace; "-o"; "jsonpath=" ^ jsonpath ]
  |> listed_names ~what:(Printf.sprintf "Secrets in namespace %s" namespace)
  |> Result.map
       (List.filter (fun name ->
          name <> Sol_cli_manifest.runtime_secret_name
          && String.ends_with ~suffix:"-secrets" name))
;;

let require_namespaces namespaces =
  match namespaces with
  | [] -> Error "no target namespaces found for this workspace"
  | _ -> Ok ()
;;

let iter_namespaces namespaces ~f =
  List.fold_left (fun acc ns -> Result.bind acc (fun () -> f ns)) (Ok ()) namespaces
;;

let fold_namespaces namespaces ~init ~f =
  List.fold_left (fun acc ns -> Result.bind acc (fun x -> f x ns)) (Ok init) namespaces
;;

let list_live_workloads ~ctx ~kind ~namespace =
  match
    Sol_cli_kubectl.get_raw ~ctx ~args:[ "get"; kind; "-n"; namespace; "-o"; "name" ]
  with
  | Error e when Sol_cli_kubectl.classify e = No_resource_type -> Ok []
  | result ->
    listed_names ~what:(Printf.sprintf "%ss in namespace %s" kind namespace) result
;;

type rotation =
  { namespace : string
  ; secrets : (string * (string * string) list) list
  ; workloads : string list
  }

let read_rotation ~ctx ?(declared = []) namespace =
  let* runtime = get_secret_json ~ctx namespace in
  let* live_workload_secret_names = list_workload_secrets ~ctx namespace in
  let workload_secret_names =
    List.sort_uniq String.compare (declared @ live_workload_secret_names)
  in
  let* workload_secrets =
    fold_namespaces workload_secret_names ~init:[] ~f:(fun acc name ->
      let* json = get_named_secret_json ~ctx ~name namespace in
      Ok ((name, existing_data json) :: acc))
  in
  let* deployments = list_live_workloads ~ctx ~kind:"deployment" ~namespace in
  let* rollouts = list_live_workloads ~ctx ~kind:"rollout" ~namespace in
  Ok
    { namespace
    ; secrets =
        (Sol_cli_manifest.runtime_secret_name, existing_data runtime)
        :: List.rev workload_secrets
    ; workloads = deployments @ rollouts
    }
;;

let read_rotations ~ctx ?(declared = []) namespaces =
  let* rotations =
    fold_namespaces namespaces ~init:[] ~f:(fun acc namespace ->
      let declared_here =
        declared
        |> List.filter_map (fun (ns, name) ->
          if String.equal ns namespace then Some name else None)
      in
      let* rotation = read_rotation ~ctx ~declared:declared_here namespace in
      Ok (rotation :: acc))
  in
  Ok (List.rev rotations)
;;

let external_secret_targets ~ctx namespace =
  let outcome =
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:
        [ "get"
        ; "externalsecrets"
        ; "-n"
        ; namespace
        ; "-o"
        ; "jsonpath={range \
           .items[*]}{.metadata.name}{\\t}{.spec.target.name}{\"\\n\"}{end}"
        ]
  in
  match outcome with
  | Ok output ->
    let output = output.Sol_cli_process.stdout in
    Ok
      (output
       |> String.split_on_char '\n'
       |> List.map String.trim
       |> List.filter (fun line -> line <> "")
       |> List.map (fun line ->
         match String.split_on_char '\t' line with
         | [ _name; target ] when String.trim target <> "" -> String.trim target
         | [ name ] -> String.trim name
         | name :: _ -> String.trim name
         | [] -> line))
  | Error error ->
    let message = Sol_cli_process.error_to_string error in
    if
      Sol_cli_string.contains ~needle:"doesn't have a resource type" message
      || Sol_cli_string.contains ~needle:"no matches for kind" message
    then Ok []
    else
      Error
        (Printf.sprintf
           "could not determine whether namespace %s rotates secrets through External \
            Secrets Operator: %s"
           namespace
           message)
;;

let refuse_external_secret_rotation ~ctx rotations =
  iter_namespaces rotations ~f:(fun { namespace; secrets; _ } ->
    let* managed = external_secret_targets ~ctx namespace in
    match List.filter (fun (name, _) -> List.mem name managed) secrets with
    | [] -> Ok ()
    | (name, _) :: _ ->
      Error
        (Printf.sprintf
           "refusing to rotate %s in namespace %s: it is managed by an ExternalSecret, \
            so the External Secrets Operator owns its value and would restore the \
            previous one on its next reconcile -- the rotation would be reported as \
            applied and then silently undone. Rotate the value in the provider store the \
            ExternalSecret reads from, or remove that ExternalSecret's ownership first."
           name
           namespace))
;;

let restart_workloads ~ctx ~namespace names =
  let* () =
    iter_namespaces names ~f:(fun name ->
      let* () =
        match Sol_cli_kubectl.rollout_restart ~ctx ~kind:name ~namespace with
        | Ok _ -> Ok ()
        | Error (Sol_cli_process.Non_zero r) ->
          Error
            (Printf.sprintf
               "could not restart %s in %s: %s"
               name
               namespace
               (String.trim r.stderr))
        | Error e -> Error (Sol_cli_process.error_to_string e)
      in
      match
        Sol_cli_kubectl.rollout_status_with_timeout
          ~ctx
          ~kind_name:name
          ~namespace
          ~timeout_s:120
      with
      | Ok _ -> Ok ()
      | Error (Sol_cli_process.Non_zero r) ->
        Error
          (Printf.sprintf
             "%s did not become healthy after the rotation restart: %s"
             name
             (String.trim r.stderr))
      | Error e -> Error (Sol_cli_process.error_to_string e))
  in
  Ok names
;;

let restart_all ~ctx rotations =
  iter_namespaces rotations ~f:(fun { namespace; workloads; _ } ->
    let* _names = restart_workloads ~ctx ~namespace workloads in
    Ok ())
;;

let set ~ctx ~workspace:_ ~namespaces ~declared ~key ~value =
  let* () = validate_key key in
  let* () = require_namespaces namespaces in
  let* () = iter_namespaces namespaces ~f:(ensure_namespace ~ctx) in
  let* rotations = read_rotations ~ctx ~declared namespaces in
  let* () = refuse_external_secret_rotation ~ctx rotations in
  let* () =
    iter_namespaces rotations ~f:(fun { namespace; secrets; _ } ->
      iter_namespaces secrets ~f:(fun (secret_name, existing_data) ->
        apply_manifest
          ~ctx
          (named_secret_manifest ~secret_name ~existing_data ~namespace ~key ~value)))
  in
  let* () = restart_all ~ctx rotations in
  Ok (Applied namespaces)
;;

let verify_required_keys ~ctx ~namespace ~secret_name ~required_keys =
  let* json = get_named_secret_json ~ctx ~name:secret_name namespace in
  let data = existing_data json in
  let missing =
    required_keys
    |> List.filter (fun key ->
      match List.assoc_opt key data with
      | Some value -> String.trim value = ""
      | None -> true)
  in
  match missing with
  | [] -> Ok ()
  | _ ->
    Error
      (Printf.sprintf
         "%s/%s does not hold the required non-empty secret key(s): %s. Sol's ordinary \
          deploy and rollback deliver secret references only and never write values; \
          create or update them with `sol secret set --target <env>/<provider>/<region> \
          <KEY>` (or your secret authority), then try again."
         namespace
         secret_name
         (String.concat ", " missing))
;;

let verify_workload_secret ~ctx (spec : Sol_cli_deployment_plan.service_spec) =
  verify_required_keys
    ~ctx
    ~namespace:(Sol_cli_deployment_plan.namespace_to_string spec.namespace)
    ~secret_name:
      (Sol_cli_manifest.workload_secret_name
         (Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name))
    ~required_keys:(Sol_cli_manifest.required_secret_keys (List.map fst spec.secrets))
;;

let verify_runtime_secret ~ctx ~namespace =
  verify_required_keys
    ~ctx
    ~namespace
    ~secret_name:Sol_cli_manifest.runtime_secret_name
    ~required_keys:(Sol_cli_manifest.required_secret_keys [])
;;

let read_keys ~ctx namespace =
  let* json = get_secret_json ~ctx namespace in
  match json with
  | None -> Ok []
  | Some json -> Ok (List.map fst (data_keys json))
;;

let list ~ctx ~workspace:_ ~namespaces =
  let* () = require_namespaces namespaces in
  let* keys =
    fold_namespaces namespaces ~init:[] ~f:(fun acc namespace ->
      let* keys = read_keys ~ctx namespace in
      Ok (keys @ acc))
  in
  Ok (Listed (List.sort_uniq String.compare keys))
;;

let delete ~ctx ~workspace:_ ~namespaces ~key =
  let* () = validate_key_format key in
  let* () = require_namespaces namespaces in
  let* rotations = read_rotations ~ctx namespaces in
  let* () = refuse_external_secret_rotation ~ctx rotations in
  let patch = Printf.sprintf "[{\"op\":\"remove\",\"path\":\"/data/%s\"}]" key in
  let remove_from namespace name =
    match
      Sol_cli_kubectl.patch
        ~ctx
        ~resource:"secret"
        ~name
        ~namespace
        ~patch_type:"json"
        ~patch
    with
    | Ok _ -> Ok ()
    | Error (Sol_cli_process.Non_zero result) ->
      Error
        (Printf.sprintf
           "kubectl patch secret/%s in namespace %s failed: %s"
           name
           namespace
           result.stderr)
    | Error e -> Error (Sol_cli_process.error_to_string e)
  in
  let* () =
    iter_namespaces rotations ~f:(fun { namespace; secrets; _ } ->
      iter_namespaces secrets ~f:(fun (name, data) ->
        if List.mem_assoc key data then remove_from namespace name else Ok ()))
  in
  let* () = restart_all ~ctx rotations in
  Ok (Deleted namespaces)
;;
