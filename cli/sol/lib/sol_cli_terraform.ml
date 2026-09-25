let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd

(* INFRA-076: every command that takes the state lock runs under a supervisor
   (Sol_cli_supervised), so Sol's death cannot kill Terraform abruptly, and each
   run leaves an operation record. The record is keyed by the state it acts on --
   the root plus its backend configuration, as [init] last configured it -- not by
   the root alone, because every target of a provider shares one root. *)
let operation_key ~chdir ~backend_config =
  let digest =
    Digest.to_hex
      (Digest.string
         (String.concat "\x00" (chdir :: List.sort String.compare backend_config)))
  in
  Printf.sprintf "%s-%s" (Filename.basename chdir) (String.sub digest 0 16)
;;

let configured : (string, string) Hashtbl.t = Hashtbl.create 4

let key_for chdir =
  match Hashtbl.find_opt configured chdir with
  | Some key -> key
  | None -> operation_key ~chdir ~backend_config:[]
;;

let previous_operation ~chdir ~backend_config =
  Sol_cli_supervised.latest ~key:(operation_key ~chdir ~backend_config)
;;

let acknowledge_previous_operation ~chdir ~backend_config =
  Sol_cli_supervised.acknowledge ~key:(operation_key ~chdir ~backend_config)
;;

let supervised ~chdir c =
  let result = Sol_cli_supervised.run ~echo:true ~key:(key_for chdir) ~root:chdir c in
  (match result with
   | Ok r when r.Sol_cli_process.exit_code <> 0 ->
     let errored = Filename.concat chdir "errored.tfstate" in
     if Sys.file_exists errored
     then
       Printf.eprintf
         "\n\
          error: Terraform could not persist state to its backend and wrote it to %s.\n\
         \  That file is now the only record of what this run changed. Inspect it and \
          push it deliberately (terraform state push); Sol never pushes it for you, and \
          the next constructive command is refused until it is resolved.\n\
          %!"
         errored
   | _ -> ());
  result
;;

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
  Hashtbl.replace configured chdir (operation_key ~chdir ~backend_config);
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
  supervised
    ~chdir
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
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan" ]
        @ scope_args scope
        @ var_args ~var_files ~vars
        @ [ "-out=" ^ out ]))
;;

let plan_destroy ?(env = []) ~chdir ~var_files ~vars () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan"; "-destroy" ] @ var_args ~var_files ~vars))
;;

let apply ?(env = []) ~scope ~chdir ~var_files ~vars () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "apply"; "-auto-approve" ]
        @ scope_args scope
        @ var_args ~var_files ~vars))
;;

let destroy ?(env = []) ~chdir ~var_files ~vars () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "destroy"; "-auto-approve" ]
        @ var_args ~var_files ~vars))
;;

let state_rm ?(env = []) ~chdir ~address () =
  supervised ~chdir (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "state"; "rm"; address ])
;;

let output_json ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "output"; "-json" ])
;;

let show_json ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "show"; "-json" ])
;;

(* `terraform show -json <saved plan>`: the plan representation, with its
   resource changes, for [Sol_cli_terraform_plan] to classify. Not exported
   (SEC-008): the JSON carries sensitive values in plain text, so the only way
   out is [show_saved_plan], which logs the classified changes and never the
   JSON -- a caller cannot route it through [Sol_cli_run_log.run_phase]. *)
let show_json_plan ?(env = []) ~chdir ~plan_file () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "show"; "-json"; plan_file ])
;;

(* One read of a saved plan, shared by the two things that need it: the apply
   assertion, which classifies resource changes, and the declared-universe
   observation (FND-0055 / B2). Neither caller receives the JSON directly -- both
   go through a [Sol_cli_terraform_plan] recorder, which enforces SEC-008. *)
let saved_plan_json ?env ~chdir ~plan_file () =
  match show_json_plan ?env ~chdir ~plan_file () with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok r.Sol_cli_process.stdout
  | Ok r ->
    let detail = String.trim r.Sol_cli_process.stderr in
    Error
      (Printf.sprintf
         "terraform show exited %d%s"
         r.Sol_cli_process.exit_code
         (if detail = "" then "." else ":\n" ^ detail))
  | Error e -> Error ("could not run terraform show: " ^ Sol_cli_process.error_to_string e)
;;

let show_saved_plan ?env ~run_log ~phase ~chdir ~plan_file () =
  Sol_cli_terraform_plan.show_and_record ~run_log ~phase ~show:(fun () ->
    saved_plan_json ?env ~chdir ~plan_file ())
;;

(* The same read, recorded as the declared universe instead of as resource
   changes. Neither recorder returns the JSON. *)
let show_saved_plan_declared ?env ~run_log ~phase ~chdir ~plan_file () =
  Sol_cli_terraform_plan.show_declared_and_record ~run_log ~phase ~show:(fun () ->
    saved_plan_json ?env ~chdir ~plan_file ())
;;

(* Apply the saved plan itself. No `-auto-approve`: a saved plan applies without
   confirmation, and the point is that no re-plan happens here. *)
let apply_saved ?(env = []) ~chdir ~plan_file () =
  supervised ~chdir (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "apply"; plan_file ])
;;
