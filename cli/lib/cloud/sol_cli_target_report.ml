type kubernetes_status =
  | Not_configured
  | Misconfigured of string * string
  | Configured of string
  | Reachable of string
  | Unreachable of string * string
  | Unreadable of string * string

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

let redact_context ~verbose ~context text =
  if verbose then text else redact ~needle:context ~replacement:"<context>" text
;;

let describe ~verbose = function
  | Not_configured ->
    "not configured — this target names no kube_context, so `sol deploy` has no cluster \
     to reach. After `sol cloud apply`, run the printed `deploy_kubeconfig_command` \
     output and add the resulting context name; for a cluster you own, name its context \
     in the target."
  | Misconfigured (context, reason) ->
    if verbose
    then Printf.sprintf "misconfigured (%s): %s" context reason
    else
      Printf.sprintf
        "misconfigured: %s"
        (redact ~needle:context ~replacement:"<context>" reason)
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
  | Unreadable (context, reason) ->
    if verbose
    then
      Printf.sprintf
        "could not be probed (%s): %s — Sol cannot tell whether the cluster is reachable \
         from here"
        context
        reason
    else
      Printf.sprintf
        "could not be probed: %s — Sol cannot tell whether the cluster is reachable from \
         here"
        (redact ~needle:context ~replacement:"<context>" reason)
;;

let provider_name (target : Sol_cli_config.target) =
  Sol_cli_provider.to_string target.provider
;;

let last_operation_unavailable =
  "unavailable — Sol keeps no target-scoped operation record (ADR 0003)"
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

type deploy_handoff =
  { command : string
  ; context : string
  }

let deploy_handoff_of_outputs json =
  let field name =
    match Sol_cli_terraform_outputs.text json ~name with
    | Ok (Some value) when not (Sol_cli_string.is_blank value) -> Some (String.trim value)
    | _ -> None
  in
  match field "deploy_kubeconfig_command", field "deploy_kube_context" with
  | Some command, Some context -> Some { command; context }
  | _ -> None
;;

let labelled label = function
  | None -> []
  | Some value -> [ label, value ]
;;

let rows
      ?platform
      ?cloud
      ?drift
      ?(last_operation = last_operation_unavailable)
      ?substrate
      ?deploy_handoff
      ~verbose
      (target : Sol_cli_config.target)
      kubernetes
  =
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
    core
    @ labelled "platform" platform
    @ labelled "cloud" cloud
    @ labelled "drift" drift
    @ (match deploy_handoff with
       | None -> []
       | Some handoff ->
         [ "deploy_kubeconfig_command", handoff.command
         ; "deploy_kube_context", handoff.context
         ])
    @ labelled "last operation" (Some last_operation)
  in
  let core =
    match substrate with
    | None -> core
    | Some lines ->
      core
      @ List.map
          (fun (input, verdict) -> Printf.sprintf "substrate: %s" input, verdict)
          lines
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

let to_json
      ?platform
      ?cloud
      ?drift
      ?(last_operation = last_operation_unavailable)
      ?substrate
      ?deploy_handoff
      ~verbose
      target
      kubernetes
  =
  `Assoc
    (rows
       ?platform
       ?cloud
       ?drift
       ~last_operation
       ?substrate
       ?deploy_handoff
       ~verbose
       target
       kubernetes
     |> List.map (fun (key, value) -> key, `String value))
;;
