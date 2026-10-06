open Result.Syntax

let kinds_of_api_resources text =
  String.split_on_char '\n' text
  |> List.filter_map (fun line ->
    match
      String.split_on_char ' ' (String.trim line)
      |> List.filter (fun field -> field <> "")
      |> List.rev
    with
    | kind :: _ :: _ -> Some kind
    | _ -> None)
  |> List.sort_uniq compare
;;

let served_api_kinds env =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         ~env
         [ "kubectl"; "api-resources"; "--verbs=delete"; "--no-headers" ])
  with
  | Ok result -> Ok (kinds_of_api_resources result.stdout)
  | Error (Sol_cli_process.Non_zero result) ->
    Error
      (Printf.sprintf
         "kubectl api-resources exited %d: %s"
         result.exit_code
         (String.trim result.stderr))
  | Error error -> Error (Sol_cli_process.error_to_string error)
;;

let unserved_of_show_json ~served text =
  let field path json =
    Sol_cli_json.field path json
    |> Sol_cli_json.string
    |> Fun.flip Option.bind Sol_cli_string.non_blank
  in
  let unserved resource =
    if field [ "type" ] resource <> Some "kubernetes_manifest"
    then None
    else (
      let kind =
        match field [ "values"; "manifest"; "kind" ] resource with
        | Some _ as kind -> kind
        | None -> field [ "values"; "object"; "kind" ] resource
      in
      match kind, field [ "address" ] resource with
      | Some kind, Some address when not (List.mem kind served) -> Some (address, kind)
      | _ -> None)
  in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error message ->
    Error ("invalid `terraform show -json`: " ^ message)
  | json ->
    Sol_cli_json.require
      ~what:"unexpected `terraform show -json` shape"
      [ "values"; "root_module"; "resources" ]
      Sol_cli_json.list
      json
    |> Result.map (List.filter_map unserved)
;;

let unserved_manifest_resources ~served ~chdir =
  match Sol_cli_terraform.show_json ~chdir () with
  | Ok result -> unserved_of_show_json ~served result.stdout
  | Error (Sol_cli_process.Non_zero result) ->
    Error (Printf.sprintf "terraform show exited %d" result.exit_code)
  | Error error -> Error (Sol_cli_process.error_to_string error)
;;

let absent env =
  [ "cert-manager"
  ; "ingress-nginx"
  ; "argocd"
  ; "redpanda"
  ; Sol_cli_manifest.monitoring_namespace
  ; "postgresql"
  ]
  |> List.for_all (fun namespace ->
    not (Sol_cli_cluster.process_ok ~env [ "kubectl"; "get"; "namespace"; namespace ]))
;;

let terraform_outcome = Sol_cli_terraform_steps.terraform_outcome

let destroy ~run_log ~env ~chdir ~vars =
  let destroy_once () = Sol_cli_terraform.destroy ~env ~chdir ~var_files:[] ~vars () in
  let destroy = Sol_cli_run_log.run_phase run_log ~name:"platform-destroy" destroy_once in
  let verify_absent () =
    if not (absent env)
    then Error "platform absence verification failed after destroy"
    else Ok ()
  in
  match destroy with
  | Ok _ -> verify_absent ()
  | _ ->
    (match served_api_kinds env with
     | Error message ->
       Sol_cli_report.err
         "error: the platform destroy failed, and the recovery step could not determine \
          which kinds the cluster serves: %s"
         message;
       terraform_outcome destroy
     | Ok served ->
       (match unserved_manifest_resources ~served ~chdir with
        | Error message ->
          Sol_cli_report.err
            "error: the platform destroy failed, and the recovery step could not read \
             the platform state: %s"
            message;
          terraform_outcome destroy
        | Ok [] -> terraform_outcome destroy
        | Ok unserved ->
          Sol_cli_report.app
            "\n\
            \  platform destroy could not delete %d resource(s) whose kind this cluster \
             does not serve, so they cannot exist;\n\
            \  forgetting them in state (the objects, not the objects' absence, is what \
             Terraform cannot address):"
            (List.length unserved);
          let* () =
            List.fold_left
              (fun acc (address, kind) ->
                 let* () = acc in
                 Sol_cli_report.app
                   "    %s (%s is not served by this cluster)"
                   address
                   kind;
                 terraform_outcome
                   (Sol_cli_run_log.run_phase
                      run_log
                      ~name:"platform-destroy-forget-unserved"
                      (fun () -> Sol_cli_terraform.state_rm ~env ~chdir ~address ())))
              (Ok ())
              unserved
          in
          let retry =
            Sol_cli_run_log.run_phase run_log ~name:"platform-destroy-retry" destroy_once
          in
          (match retry with
           | Ok _ -> verify_absent ()
           | _ -> terraform_outcome retry)))
;;
