type set_val =
  | Bool of bool
  | Float of float
  | Str of string

let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd
let repo_add ~name ~url = run (cmd [ "helm"; "repo"; "add"; name; url ])
let repo_update () = run (cmd [ "helm"; "repo"; "update" ])

let upgrade_install ~release ~chart ~namespace ?version ?(values = []) ?values_yaml () =
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
  let install file_flags =
    run
      ~echo:true
      (cmd
         ([ "helm"; "upgrade"; "--install"; release; chart ]
          @ [ "--namespace"; namespace; "--create-namespace" ]
          @ version_flags
          @ set_flags
          @ file_flags
          @ [ "--wait"; "--timeout"; "3m" ]))
  in
  match values_yaml with
  | None -> install []
  | Some content ->
    Sol_cli_fs.with_temp_file
      ~prefix:"sol-helm-values-"
      ~suffix:".yaml"
      content
      (fun tmp -> install [ "-f"; tmp ])
    |> Result.map_error (fun message -> Sol_cli_process.Spawn_failed message)
    |> Result.join
;;
