(* The ways a Terraform command's result is read and a destroy-path apply is run,
   shared by the command and the provider modules (REFAC-097 moved them out of
   `cmd_cloud_tf.ml` so provider destruction code can use them). *)

(* REFAC-091: the same classification [require_terraform_success] makes, returned
   as a value rather than exiting, so the destroy execution sequence can carry a
   terraform failure in its typed outcome. *)
let terraform_outcome (r : (Sol_cli_process.result, Sol_cli_process.error) result)
  : (unit, string) result
  =
  match Sol_cli_process.check r with
  | Ok _ -> Ok ()
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim r.stderr in
    Error
      (Printf.sprintf
         "terraform exited %d%s"
         r.exit_code
         (if detail = "" then "." else ":\n" ^ detail))
  | Error error ->
    Error
      (Printf.sprintf
         "could not run terraform: %s"
         (Sol_cli_process.error_to_string error))
;;

(* Like [terraform_outcome], but keeps the command's stdout -- [terraform show
   -json <plan>] is read, not just checked. *)
let terraform_stdout (r : (Sol_cli_process.result, Sol_cli_process.error) result)
  : (string, string) result
  =
  match Sol_cli_process.check r with
  | Ok r -> Ok r.Sol_cli_process.stdout
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim r.stderr in
    Error
      (Printf.sprintf
         "terraform exited %d%s"
         r.exit_code
         (if detail = "" then "." else ":\n" ^ detail))
  | Error error ->
    Error
      (Printf.sprintf
         "could not run terraform: %s"
         (Sol_cli_process.error_to_string error))
;;

(* HARDEN-004 step 3: the one way a destroy-path apply runs. The exact scope and
   variables are planned first; the plan is classified against [policy]; the
   saved plan is applied only when every change is permitted. A plan that cannot
   be produced, read or classified refuses, and the apply is never invoked. The
   saved plan is removed however this returns. *)
let apply_asserted ~run_log ~phase_name ~policy ~scope ~chdir ~var_files ~vars ()
  : (unit, string) result
  =
  let plan_file = Filename.temp_file "sol-destroy-" ".tfplan" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove plan_file with
      | Sys_error _ -> ())
    (fun () ->
       match
         Sol_cli_terraform_plan.guarded_apply
           ~policy
           ~plan:(fun () ->
             match
               terraform_stdout
                 (Sol_cli_run_log.run_phase
                    run_log
                    ~name:(phase_name ^ "-plan")
                    (fun () ->
                       Sol_cli_terraform.plan_saved
                         ~scope
                         ~chdir
                         ~var_files
                         ~vars
                         ~out:plan_file
                         ()))
             with
             | Ok _ -> Ok plan_file
             | Error message -> Error message)
           ~show_plan:(fun file ->
             (* SEC-008: the plan JSON carries sensitive values; only the
                classified changes reach the run log. *)
             Sol_cli_terraform.show_saved_plan
               ~run_log
               ~phase:(phase_name ^ "-show")
               ~chdir
               ~plan_file:file
               ()
             |> Result.map fst)
           ~apply_plan:(fun file ->
             terraform_outcome
               (Sol_cli_run_log.run_phase run_log ~name:phase_name (fun () ->
                  Sol_cli_terraform.apply_saved ~chdir ~plan_file:file ())))
           ()
       with
       | Ok () -> Ok ()
       | Error failure -> Error (Sol_cli_terraform_plan.apply_failure_to_string failure))
;;
