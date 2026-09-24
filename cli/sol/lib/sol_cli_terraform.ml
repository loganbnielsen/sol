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

(* A plan saved to a file, so the plan that was asserted is the plan that is
   applied -- an apply that re-plans with the same arguments could differ from
   the asserted plan (HARDEN-004 step 3). *)
let plan_saved ?(env = []) ~scope ~chdir ~var_files ~vars ~out () =
  run
    ~echo:true
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan" ]
        @ scope_args scope
        @ var_args ~var_files ~vars
        @ [ "-out=" ^ out ]))
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

let state_rm ?(env = []) ~chdir ~address () =
  run ~echo:true (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "state"; "rm"; address ])
;;

let output_json ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "output"; "-json" ])
;;

let show_json ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "show"; "-json" ])
;;

(* `terraform show -json <saved plan>`: the plan representation, with its
   resource changes, for [Sol_cli_terraform_plan] to classify. *)
let show_json_plan ?(env = []) ~chdir ~plan_file () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "show"; "-json"; plan_file ])
;;

(* Apply the saved plan itself. No `-auto-approve`: a saved plan applies without
   confirmation, and the point is that no re-plan happens here. *)
let apply_saved ?(env = []) ~chdir ~plan_file () =
  run ~echo:true (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "apply"; plan_file ])
;;
