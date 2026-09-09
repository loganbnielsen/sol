type set_val = Bool of bool | Float of float | Str of string

let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd
let repo_add ~name ~url = run (cmd [ "helm"; "repo"; "add"; name; url ])
let repo_update () = run (cmd [ "helm"; "repo"; "update" ])

let upgrade_install ~release ~chart ~namespace ?version ?(values = [])
    ?values_yaml () =
  let set_flags =
    values
    |> List.concat_map (fun (k, v) ->
        match v with
        | Bool b -> [ "--set"; Printf.sprintf "%s=%s" k (string_of_bool b) ]
        | Float f -> [ "--set"; Printf.sprintf "%s=%g" k f ]
        | Str s -> [ "--set-string"; Printf.sprintf "%s=%s" k s ])
  in
  let values_file =
    Option.map
      (fun content ->
        let tmp = Filename.temp_file "sol-helm-values-" ".yaml" in
        let oc = open_out tmp in
        output_string oc content;
        close_out oc;
        tmp)
      values_yaml
  in
  Fun.protect
    ~finally:(fun () ->
      Option.iter (fun tmp -> try Sys.remove tmp with _ -> ()) values_file)
    (fun () ->
      let file_flags =
        match values_file with Some tmp -> [ "-f"; tmp ] | None -> []
      in
      let version_flags =
        match version with Some v -> [ "--version"; v ] | None -> []
      in
      let argv =
        [ "helm"; "upgrade"; "--install"; release; chart ]
        @ [ "--namespace"; namespace; "--create-namespace" ]
        @ version_flags @ set_flags @ file_flags
        @ [ "--wait"; "--timeout"; "3m" ]
      in
      run ~echo:true (cmd argv))
