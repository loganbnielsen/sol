type set_val =
  | Bool of bool
  | Float of float
  | Str of string

let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd
let repo_add ~name ~url = run (cmd [ "helm"; "repo"; "add"; name; url ])
let repo_update () = run (cmd [ "helm"; "repo"; "update" ])

let upgrade_install_argv
      ~ctx
      ~release
      ~chart
      ~namespace
      ?version
      ?(values = [])
      ?values_file
      ()
  =
  let set_flags =
    values
    |> List.concat_map (fun (k, v) ->
      match v with
      | Bool b -> [ "--set"; Printf.sprintf "%s=%s" k (string_of_bool b) ]
      | Float f -> [ "--set"; Printf.sprintf "%s=%g" k f ]
      | Str s -> [ "--set-string"; Printf.sprintf "%s=%s" k s ])
  in
  let version_flags =
    match version with
    | Some v -> [ "--version"; v ]
    | None -> []
  in
  let file_flags =
    match values_file with
    | Some path -> [ "-f"; path ]
    | None -> []
  in
  [ "helm"; "upgrade"; "--install"; release; chart ]
  @ [ "--namespace"; namespace; "--create-namespace" ]
  @ version_flags
  @ set_flags
  @ file_flags
  @ Sol_cli_kube_destination.helm_context_args ctx
  @ [ "--wait"; "--timeout"; "3m" ]
;;

let upgrade_install
      ~ctx
      ~release
      ~chart
      ~namespace
      ?version
      ?(values = [])
      ?values_yaml
      ()
  =
  let invoke ?values_file () =
    run
      ~echo:true
      (cmd
         (upgrade_install_argv
            ~ctx
            ~release
            ~chart
            ~namespace
            ?version
            ~values
            ?values_file
            ()))
  in
  match values_yaml with
  | None -> invoke ()
  | Some content ->
    Sol_cli_fs.with_temp_file
      ~prefix:"sol-helm-values-"
      ~suffix:".yaml"
      content
      (fun tmp -> invoke ~values_file:tmp ())
    |> Result.map_error (fun message -> Sol_cli_process.Spawn_failed message)
    |> Result.join
;;
