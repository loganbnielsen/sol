let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd

let which_check () =
  match run (cmd [ "which"; "terraform" ]) with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false
;;

type scope =
  | Whole_root
  | Targets of string * string list

let whole_root = Whole_root

let targets first rest =
  if String.trim first = "" then invalid_arg "Terraform target must not be empty";
  Targets (first, rest)
;;

let scope_args = function
  | Whole_root -> []
  | Targets (first, rest) -> List.map (fun target -> "-target=" ^ target) (first :: rest)
;;

let init ?(env = []) ~chdir ~backend_config () =
  run
    ~echo:true
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "init"; "-reconfigure" ]
        @ List.map (fun value -> "-backend-config=" ^ value) backend_config))
;;

let kv_args pairs = List.map (fun (k, v) -> k ^ "=" ^ v) pairs

let var_args ~var_files ~vars =
  let varfile_args = List.map (fun f -> "-var-file=" ^ f) var_files in
  let var_args = List.map (fun v -> "-var=" ^ v) vars in
  varfile_args @ var_args
;;

let plan ?(env = []) ~scope ~chdir ~var_files ~vars () =
  run
    ~echo:true
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan" ]
        @ scope_args scope
        @ var_args ~var_files ~vars))
;;

let plan_destroy ?(env = []) ~chdir ~var_files ~vars () =
  run
    ~echo:true
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan"; "-destroy" ] @ var_args ~var_files ~vars))
;;

let apply ?(env = []) ~scope ~chdir ~var_files ~vars () =
  run
    ~echo:true
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "apply"; "-auto-approve" ]
        @ scope_args scope
        @ var_args ~var_files ~vars))
;;

let destroy ?(env = []) ~chdir ~var_files ~vars () =
  run
    ~echo:true
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "destroy"; "-auto-approve" ]
        @ var_args ~var_files ~vars))
;;

let output_json ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "output"; "-json" ])
;;
