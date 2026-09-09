type common_fields = {
  namespace : Sol_cli_kubernetes_name.namespace;
  k8s_name : Sol_cli_kubernetes_name.k8s_name;
  domain : string;
  primitive : string;
  spec_image : string;
  config : (string * string) list;
  secrets : (string * string) list;
}

type deployment_fields = {
  replicas : int;
  cpu : Sol_cli_toml.cpu_quantity;
  memory : Sol_cli_toml.memory_quantity;
  rollout_strategy : Sol_cli_toml.rollout_strategy option;
  extra_labels : (string * string) list;
  progressive_delivery : Sol_cli_toml.progressive_delivery option;
}

type http_fields = {
  deployment : deployment_fields;
  ingress_host : Sol_cli_toml.hostname option;
  ingress_path : Sol_cli_toml.ingress_path option;
}

type worker_fields = { deployment : deployment_fields }
type fn_fields = { schedule : string }

type render_workload =
  | Render_svc of http_fields
  | Render_worker of worker_fields
  | Render_fn of fn_fields

type render_spec_t = { common : common_fields; workload : render_workload }

let render ~workspace ?env ?(image = "")
    ?(secret_backend = Sol_cli_manifest.Kubernetes_live) { common; workload } =
  let { namespace; k8s_name; domain; primitive; spec_image; config; secrets } =
    common
  in
  let ns = Sol_cli_kubernetes_name.namespace_to_string namespace in
  let name = Sol_cli_kubernetes_name.k8s_name_to_string k8s_name in
  let img = if image = "" then spec_image else image in
  let cfg_hash = Sol_cli_manifest.config_hash config in
  Sol_cli_manifest.(
    let ns_yaml = namespace_doc ~ns in
    let secret_resource_result =
      match secret_backend with
      | Kubernetes_live -> (
          let value_from_env key =
            match Sys.getenv_opt key with Some value -> value | None -> ""
          in
          let missing_keys =
            List.filter_map
              (fun (k, _) ->
                match Sys.getenv_opt k with Some _ -> None | None -> Some k)
              secrets
          in
          match missing_keys with
          | _ :: _ ->
              Error
                (Printf.sprintf
                   "Kubernetes_live render failed: required secret env var(s) \
                    not set: %s"
                   (String.concat ", " missing_keys))
          | [] ->
              let extra_secrets =
                List.map (fun (k, _) -> (k, value_from_env k)) secrets
              in
              let base_secrets =
                List.map (fun (k, _) -> (k, value_from_env k)) default_secrets
              in
              Ok (secret_doc ~base_secrets ~extra_secrets ~ns ~name ()))
      | Kubernetes_placeholder ->
          let extra_secrets = List.map (fun (k, _) -> (k, "")) secrets in
          Ok (secret_doc ~extra_secrets ~redact:true ~ns ~name ())
      | External_secrets { store_ref; store_kind; key_prefix; refresh_interval }
        ->
          let all_keys = List.map fst default_secrets @ List.map fst secrets in
          Ok
            (external_secret_doc ~store_ref ~store_kind ~key_prefix
               ~refresh_interval ~secret_keys:all_keys ~ns ~name)
    in
    Result.map
      (fun secret_resource ->
        let common_resources =
          [
            service_account_doc ~ns ~name;
            configmap_doc ~extra_env:config ~ns ~name ();
            secret_resource;
            network_policy_doc ~ns ~name;
          ]
        in
        let deployment_resources ~shape ~ingress_host ~ingress_path ~deployment
            =
          let {
            replicas;
            cpu;
            memory;
            rollout_strategy;
            extra_labels;
            progressive_delivery;
          } =
            deployment
          in
          let cpu = Sol_cli_toml.cpu_quantity_to_string cpu in
          let memory = Sol_cli_toml.memory_quantity_to_string memory in
          match progressive_delivery with
          | Some pd -> (
              let rollout =
                rollout_doc ~extra_labels ~secret_keys:(List.map fst secrets)
                  ~config_hash:cfg_hash ?env ~shape ~replicas ~cpu ~memory ~ns
                  ~name ~image:img ~pd ~workspace ~domain ~primitive ()
              in
              match pd with
              | Sol_cli_toml.Blue_green ->
                  [
                    rollout;
                    blue_green_service_docs ~ns ~name;
                    (if shape = Http_service then
                       ingress_doc ~ingress_host ~ingress_path ~ns
                         ~name:(name ^ "-active") ()
                     else "");
                  ]
                  |> List.filter (fun s -> s <> "")
              | Sol_cli_toml.Canary _ ->
                  let svc =
                    if shape = Http_service then [ service_doc ~ns ~name ]
                    else []
                  in
                  let ingr =
                    if shape = Http_service then
                      [ ingress_doc ~ingress_host ~ingress_path ~ns ~name () ]
                    else []
                  in
                  [ rollout ] @ svc @ ingr)
          | None ->
              let rollout_strategy =
                Option.value rollout_strategy
                  ~default:Sol_cli_toml.RollingUpdate
              in
              [
                deployment_doc ~rollout_strategy ~extra_labels
                  ~config_hash:cfg_hash ~secret_keys:(List.map fst secrets) ?env
                  ~shape ~replicas ~cpu ~memory ~ns ~name ~image:img ~workspace
                  ~domain ~primitive ();
              ]
        in
        let resources =
          match workload with
          | Render_svc { deployment; ingress_host; ingress_path } -> (
              let ingress_host =
                match ingress_host with
                | Some host -> Sol_cli_toml.hostname_to_string host
                | None -> ""
              in
              let ingress_path =
                match ingress_path with
                | Some path -> Sol_cli_toml.ingress_path_to_string path
                | None -> "/"
              in
              let resources =
                deployment_resources ~shape:Http_service ~ingress_host
                  ~ingress_path ~deployment
              in
              match deployment.progressive_delivery with
              | Some _ -> resources
              | None ->
                  resources
                  @ [
                      service_doc ~ns ~name;
                      ingress_doc ~ingress_host ~ingress_path ~ns ~name ();
                    ])
          | Render_worker { deployment } ->
              deployment_resources ~shape:Background_worker ~ingress_host:""
                ~ingress_path:"/" ~deployment
          | Render_fn { schedule } ->
              [
                cronjob_doc ~secret_keys:(List.map fst secrets) ?env ~ns ~name
                  ~image:img ~schedule ~workspace ~domain ();
              ]
        in
        (ns_yaml, String.concat "\n" (common_resources @ resources)))
      secret_resource_result)

let render_spec ~workspace ?env ?(image = "")
    ?(secret_backend = Sol_cli_manifest.Kubernetes_live)
    (s : Sol_cli_deployment_plan.service_spec) =
  let primitive =
    match s.primitive with
    | Sol_cli_deployment_plan.Svc -> "svc"
    | Sol_cli_deployment_plan.Worker -> "worker"
    | Sol_cli_deployment_plan.Fn -> "fn"
  in
  let common =
    {
      namespace = s.namespace;
      k8s_name = s.k8s_name;
      domain = s.domain;
      primitive;
      spec_image = s.image;
      config = s.config;
      secrets = s.secrets;
    }
  in
  let deployment =
    {
      replicas = s.replicas;
      cpu = s.cpu;
      memory = s.memory;
      rollout_strategy = s.rollout_strategy;
      extra_labels = s.extra_labels;
      progressive_delivery = s.progressive_delivery;
    }
  in
  let workload =
    match s.primitive with
    | Svc ->
        Render_svc
          {
            deployment;
            ingress_host = s.ingress_host;
            ingress_path = s.ingress_path;
          }
    | Worker -> Render_worker { deployment }
    | Fn ->
        let schedule = Option.value s.schedule ~default:"0 * * * *" in
        Render_fn { schedule }
  in
  render ~workspace ?env ~image ~secret_backend { common; workload }
