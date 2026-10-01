type kubernetes_status =
  | Not_configured
  | Configured of string
  | Reachable of string
  | Unreachable of string * string

let redact ~needle ~replacement haystack =
  if needle = ""
  then haystack
  else (
    let length = String.length haystack in
    let n = String.length needle in
    let buffer = Buffer.create length in
    let rec go i =
      if i >= length
      then ()
      else if i + n <= length && String.sub haystack i n = needle
      then (
        Buffer.add_string buffer replacement;
        go (i + n))
      else (
        Buffer.add_char buffer haystack.[i];
        go (i + 1))
    in
    go 0;
    Buffer.contents buffer)
;;

let describe ~verbose = function
  | Not_configured ->
    "not configured — this target names no kube_context, so `sol deploy` has no cluster \
     to reach. After `sol cloud apply`, run the printed `deploy_kubeconfig_command` \
     output and add the resulting context name; for a cluster you own, name its context \
     in the target."
  | Configured context ->
    if verbose
    then Printf.sprintf "configured (%s) — not checked; pass --check to probe it" context
    else "configured — not checked; pass --check to probe it"
  | Reachable context ->
    if verbose then Printf.sprintf "reachable (%s)" context else "reachable"
  | Unreachable (context, reason) ->
    if verbose
    then Printf.sprintf "unreachable (%s): %s" context reason
    else
      Printf.sprintf
        "unreachable: %s"
        (redact ~needle:context ~replacement:"<context>" reason)
;;

let provider_name (target : Sol_cli_config.target) =
  Sol_cli_provider.to_string target.provider
;;

let context_is_configured (destination : Sol_cli_kube_destination.t) =
  let named name =
    String.equal (String.trim name) destination.Sol_cli_kube_destination.context
  in
  match
    Sol_cli_process.run
      ~echo:false
      (Sol_cli_process.cmd
         ~env:(Sol_cli_kube_destination.environment destination)
         [ "kubectl"; "config"; "get-contexts"; "-o"; "name" ])
  with
  | Ok result ->
    result.Sol_cli_process.stdout |> String.split_on_char '\n' |> List.exists named
  | Error _ -> true
;;

let rows ?platform ~verbose (target : Sol_cli_config.target) kubernetes =
  let core =
    [ "provider", provider_name target
    ; "region", target.region
    ; "cluster", Option.value target.cluster_name ~default:"(unnamed)"
    ; "registry", Option.value target.registry ~default:"(provider default)"
    ; "base domain", Option.value target.base_domain ~default:"(none)"
    ; "kubernetes", describe ~verbose kubernetes
    ]
  in
  let core =
    match platform with
    | None -> core
    | Some status -> core @ [ "platform", status ]
  in
  if not verbose
  then core
  else
    core
    @ [ "env", target.env
      ; "target", target.name
      ; "kube context", Option.value target.kube_context ~default:"(none set)"
      ; "kubeconfig", Option.value target.kubeconfig ~default:"(none set)"
      ]
;;

let to_json ?platform ~verbose target kubernetes =
  `Assoc
    (rows ?platform ~verbose target kubernetes
     |> List.map (fun (key, value) -> key, `String value))
;;
