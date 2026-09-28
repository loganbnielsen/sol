type backend =
  | Local
  | Self_hosted_durable
  | External

let backend_of_string = function
  | "local" -> Some Local
  | "self_hosted_durable" -> Some Self_hosted_durable
  | "external" -> Some External
  | _ -> None
;;

let backend_to_string = function
  | Local -> "local"
  | Self_hosted_durable -> "self_hosted_durable"
  | External -> "external"
;;

type resolution =
  | Url of string
  | No_url of string

let resolve ~backend ?base_domain ?override () =
  match override with
  | Some url -> Url url
  | None ->
    (match backend with
     | Local -> Url "http://localhost:3000"
     | Self_hosted_durable ->
       (match base_domain with
        | Some d -> Url (Printf.sprintf "https://grafana.%s" d)
        | None ->
          No_url "self_hosted_durable requires --base-domain to resolve the Grafana URL")
     | External ->
       No_url
         "no generated URL for the \"external\" backend -- check your configured \
          observability provider directly")
;;

let effective_backend_and_base_domain ~explicit_backend ~explicit_base_domain ~target () =
  let open Result.Syntax in
  match target with
  | None -> Ok (Option.value explicit_backend ~default:Local, explicit_base_domain)
  | Some target_path ->
    let* cfg =
      Sol_cli_config.load_for_target ~target:target_path
      |> Result.map_error Sol_cli_config.error_to_string
    in
    let t = cfg.target in
    let target_backend =
      match t.observability_backend with
      | None -> Ok None
      | Some s ->
        (match backend_of_string s with
         | Some b -> Ok (Some b)
         | None ->
           Error
             (Printf.sprintf
                "target %s has invalid observability_backend %S (expected: local, \
                 self_hosted_durable, external)"
                target_path
                s))
    in
    let* target_backend = target_backend in
    let backend =
      match explicit_backend with
      | Some b -> b
      | None -> Option.value target_backend ~default:Local
    in
    let base_domain =
      match explicit_base_domain with
      | Some _ -> explicit_base_domain
      | None -> t.base_domain
    in
    Ok (backend, base_domain)
;;
