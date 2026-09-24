type mode =
  | Local
  | Customer_cloud
  | Sol_hosted

type action_result =
  | Applied of string list
  | Deleted of string list
  | Listed of string list
  | Hosted_unavailable of string

let ( let* ) = Result.bind

let mode_of_env env =
  let normalized = String.lowercase_ascii (String.trim env) in
  match normalized with
  | "hosted" | "sol_hosted" | "sol-hosted" -> Ok Sol_hosted
  (* REFAC-086: `dev` was an alias here until it was retired as user vocabulary
     when `sol dev up` became `sol local up` (REFAC-083). A retired word left in
     a config vocabulary is how it comes back — in examples, in error messages,
     in migrations — so it is deleted rather than tolerated. *)
  | "local" -> Ok Local
  | "cloud" | "customer_cloud" | "customer-cloud" -> Ok Customer_cloud
  | _ ->
    Error
      (Printf.sprintf
         "unknown secret environment %S; expected one of: hosted, sol_hosted, \
          sol-hosted, local, cloud, customer_cloud, customer-cloud"
         env)
;;

let is_key_char = function
  | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false
;;

let validate_key key =
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

let yaml_quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 ->
        Buffer.add_string b (Printf.sprintf "\\x%02X" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b
;;

let render_mapping ~indent pairs =
  pairs
  |> List.map (fun (k, v) -> Printf.sprintf "%s%s: %s" indent k (yaml_quote v))
  |> String.concat "\n"
;;

let render_optional_mapping ~name pairs =
  match pairs with
  | [] -> []
  | _ -> [ name ^ ":"; render_mapping ~indent:"  " pairs ]
;;

let render_secret_manifest secret =
  let lines =
    [ "---"
    ; "apiVersion: " ^ secret.api_version
    ; "kind: " ^ secret.kind
    ; "metadata:"
    ; "  name: " ^ secret.metadata.name
    ; "  namespace: " ^ secret.metadata.namespace
    ; "type: " ^ secret.secret_type
    ]
    @ render_optional_mapping ~name:"data" secret.data
    @ [ "stringData:"; render_mapping ~indent:"  " secret.string_data ]
  in
  String.concat "\n" lines ^ "\n"
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
  | Hosted_unavailable msg -> msg
;;

(* FEAT-063: secrets are cluster objects, so every entry point takes the
   destination-side context and passes it to kubectl. Nothing here reads the
   ambient context. *)
let apply_manifest ~ctx yaml =
  let path = Sol_cli_manifest.write_tmp yaml in
  let result =
    match Sol_cli_kubectl.apply ~ctx ~file:path with
    | Ok () -> Ok ()
    | Error e -> Error (Sol_cli_process.error_to_string e)
  in
  (try Sys.remove path with
   | _ -> ());
  result
;;

(* BUG-040 / FND-0031: only kubectl's own NotFound means the Secret is absent.
   Every other failure -- no connection, Forbidden, a timeout, a body that does not
   parse -- is an error. [set] writes what it read back into the Secret, so reading
   "could not ask" as "nothing there" would rewrite it without its other keys. *)
let get_named_secret_json ~ctx ~name namespace =
  match Sol_cli_kubectl.get ~ctx ~resource:"secret" ~name ~namespace ~output:"json" with
  | Ok r ->
    (try Ok (Some (Yojson.Safe.from_string r.Sol_cli_process.stdout)) with
     | Yojson.Json_error message ->
       Error (Printf.sprintf "could not parse Secret %s/%s: %s" namespace name message))
  | Error (Sol_cli_process.Non_zero { stderr; _ })
    when Sol_cli_port_forward.string_contains ~needle:"NotFound" stderr -> Ok None
  | Error e ->
    Error
      (Printf.sprintf
         "could not read Secret %s/%s: %s"
         namespace
         name
         (Sol_cli_process.error_to_string e))
;;

(* The names a listing printed, or why it could not be read. A listing that
   failed is never an empty one (BUG-040). *)
let listed_names ~what (result : (Sol_cli_process.result, Sol_cli_process.error) result) =
  match result with
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    Ok
      (String.split_on_char '\n' r.Sol_cli_process.stdout
       |> List.map String.trim
       |> List.filter (fun name -> name <> ""))
  | Ok r ->
    Error
      (Printf.sprintf
         "could not list %s: %s"
         what
         (let detail = String.trim r.Sol_cli_process.stderr in
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

(* List per-workload secret names in a namespace — secrets ending in "-secrets"
   except the shared sol-secrets object, which is patched separately for
   Argo Rollout compatibility. *)
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

let apply_to_named_secret ~ctx ~secret_name ~namespace ~key ~value =
  let* existing = get_named_secret_json ~ctx ~name:secret_name namespace in
  let existing_data = existing_data existing in
  let yaml = named_secret_manifest ~secret_name ~existing_data ~namespace ~key ~value in
  apply_manifest ~ctx yaml
;;

let hosted_stub _env =
  Error
    "hosted secret management will use the Sol control-plane API; no hosted endpoint is \
     configured yet"
;;

let require_namespaces namespaces =
  match namespaces with
  | [] -> Error "no target namespaces found for this workspace"
  | _ -> Ok ()
;;

let validate_operation_context ~env ~namespaces =
  let* mode = mode_of_env env in
  match mode with
  | Sol_hosted -> hosted_stub env
  | Local | Customer_cloud ->
    let* () = require_namespaces namespaces in
    Ok namespaces
;;

let iter_namespaces namespaces ~f =
  List.fold_left (fun acc ns -> Result.bind acc (fun () -> f ns)) (Ok ()) namespaces
;;

let fold_namespaces namespaces ~init ~f =
  List.fold_left (fun acc ns -> Result.bind acc (fun x -> f x ns)) (Ok init) namespaces
;;

(* SEC-004: rotation must be verified, not assumed. The env-var secret contract
   means a running pod never observes a rotated value, so the restart is what
   makes the new value take effect; waiting for `rollout status` is what lets Sol
   claim the workload returned to healthy state. A workload that never becomes
   healthy is an error, not a silent success. *)
let list_live_workloads ~ctx ~kind ~namespace =
  match
    Sol_cli_kubectl.get_raw ~ctx ~args:[ "get"; kind; "-n"; namespace; "-o"; "name" ]
  with
  | Ok r
    when r.Sol_cli_process.exit_code <> 0
         && (Sol_cli_port_forward.string_contains
               ~needle:"doesn't have a resource type"
               r.Sol_cli_process.stderr
             || Sol_cli_port_forward.string_contains
                  ~needle:"could not find the requested resource"
                  r.Sol_cli_process.stderr) -> Ok []
  | result ->
    listed_names ~what:(Printf.sprintf "%ss in namespace %s" kind namespace) result
;;

(* Rollouts only exist when progressive delivery is enabled; an absent CRD
   yields an empty list rather than a failure, so listing tolerates it. *)
let restart_and_verify ~ctx ~namespace =
  let* deployments = list_live_workloads ~ctx ~kind:"deployment" ~namespace in
  let* rollouts = list_live_workloads ~ctx ~kind:"rollout" ~namespace in
  let names = deployments @ rollouts in
  let* () =
    iter_namespaces names ~f:(fun name ->
      let* () =
        match Sol_cli_kubectl.rollout_restart ~ctx ~kind:name ~namespace with
        | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok ()
        | Ok r ->
          Error
            (Printf.sprintf
               "could not restart %s in %s: %s"
               name
               namespace
               (String.trim r.Sol_cli_process.stderr))
        | Error e -> Error (Sol_cli_process.error_to_string e)
      in
      match
        Sol_cli_kubectl.rollout_status_with_timeout
          ~ctx
          ~kind_name:name
          ~namespace
          ~timeout_s:120
      with
      | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok ()
      | Ok r ->
        Error
          (Printf.sprintf
             "%s did not become healthy after the rotation restart: %s"
             name
             (String.trim r.Sol_cli_process.stderr))
      | Error e -> Error (Sol_cli_process.error_to_string e))
  in
  Ok names
;;

let patch_workload_secrets ~ctx ~namespace ~key ~value =
  let* secret_names = list_workload_secrets ~ctx namespace in
  iter_namespaces secret_names ~f:(fun secret_name ->
    apply_to_named_secret ~ctx ~secret_name ~namespace ~key ~value)
;;

let set ~ctx ~env ~workspace:_ ~namespaces ~key ~value =
  let* () = validate_key key in
  let* namespaces = validate_operation_context ~env ~namespaces in
  let* () =
    iter_namespaces namespaces ~f:(fun namespace ->
      (* Patch sol-secrets for Argo Rollout workloads *)
      let* existing = get_secret_json ~ctx namespace in
      let existing_data = existing_data existing in
      let yaml = secret_manifest ~existing_data ~namespace ~key ~value in
      let* () = apply_manifest ~ctx yaml in
      (* Also patch each per-service secret so standard Deployment workloads
         (which mount <svc>-secrets, not sol-secrets) see the updated value
         immediately on next restart. *)
      let* () = patch_workload_secrets ~ctx ~namespace ~key ~value in
      let* _names = restart_and_verify ~ctx ~namespace in
      Ok ())
  in
  Ok (Applied namespaces)
;;

let read_keys ~ctx namespace =
  let* json = get_secret_json ~ctx namespace in
  match json with
  | None -> Ok []
  | Some json -> Ok (List.map fst (data_keys json))
;;

let list ~ctx ~env ~workspace:_ ~namespaces =
  let* namespaces = validate_operation_context ~env ~namespaces in
  let* keys =
    fold_namespaces namespaces ~init:[] ~f:(fun acc namespace ->
      let* keys = read_keys ~ctx namespace in
      Ok (keys @ acc))
  in
  Ok (Listed (List.sort_uniq String.compare keys))
;;

let delete ~ctx ~env ~workspace:_ ~namespaces ~key =
  let* () = validate_key key in
  let* namespaces = validate_operation_context ~env ~namespaces in
  let patch = Printf.sprintf "[{\"op\":\"remove\",\"path\":\"/data/%s\"}]" key in
  let remove_from namespace name =
    let* existing = get_named_secret_json ~ctx ~name namespace in
    let data = existing_data existing in
    if not (List.mem_assoc key data)
    then Ok ()
    else (
      match
        Sol_cli_kubectl.patch
          ~ctx
          ~resource:"secret"
          ~name
          ~namespace
          ~patch_type:"json"
          ~patch
      with
      | Ok result when result.Sol_cli_process.exit_code = 0 -> Ok ()
      | Ok result ->
        Error
          (Printf.sprintf
             "kubectl patch secret/%s in namespace %s failed: %s"
             name
             namespace
             result.Sol_cli_process.stderr)
      | Error e -> Error (Sol_cli_process.error_to_string e))
  in
  let* () =
    iter_namespaces namespaces ~f:(fun namespace ->
      let* () = remove_from namespace Sol_cli_manifest.runtime_secret_name in
      let* secret_names = list_workload_secrets ~ctx namespace in
      let* () =
        iter_namespaces secret_names ~f:(fun secret_name ->
          remove_from namespace secret_name)
      in
      let* _names = restart_and_verify ~ctx ~namespace in
      Ok ())
  in
  Ok (Deleted namespaces)
;;
