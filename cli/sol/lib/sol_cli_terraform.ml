let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd

let which_check () =
  match run (cmd [ "which"; "terraform" ]) with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false

let init ~chdir =
  run ~echo:true (cmd [ "terraform"; "-chdir=" ^ chdir; "init" ])

let kv_args pairs = List.map (fun (k, v) -> k ^ "=" ^ v) pairs

let var_args ~var_files ~vars =
  let varfile_args = List.map (fun f -> "-var-file=" ^ f) var_files in
  let var_args = List.map (fun v -> "-var=" ^ v) vars in
  varfile_args @ var_args

let plan ~chdir ~var_files ~vars =
  run ~echo:true
    (cmd
       ([ "terraform"; "-chdir=" ^ chdir; "plan" ] @ var_args ~var_files ~vars))

let plan_destroy ~chdir ~var_files ~vars =
  run ~echo:true
    (cmd
       ([ "terraform"; "-chdir=" ^ chdir; "plan"; "-destroy" ]
       @ var_args ~var_files ~vars))

let apply ~chdir ~var_files ~vars =
  run ~echo:true
    (cmd
       ([ "terraform"; "-chdir=" ^ chdir; "apply"; "-auto-approve" ]
       @ var_args ~var_files ~vars))

let destroy ~chdir ~var_files ~vars =
  run ~echo:true
    (cmd
       ([ "terraform"; "-chdir=" ^ chdir; "destroy"; "-auto-approve" ]
       @ var_args ~var_files ~vars))

let output_json ~chdir =
  run (cmd [ "terraform"; "-chdir=" ^ chdir; "output"; "-json" ])
