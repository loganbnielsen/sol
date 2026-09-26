(* FEAT-072: one deploy attempt as a unit. See the .mli. *)

type t =
  { deployment_id : Sol_cli_deployment_id.t
  ; now : float
  }

let start () =
  let now = Unix.gettimeofday () in
  { deployment_id =
      Sol_cli_deployment_id.create ~now ~entropy:(Sol_cli_deployment_id.random_entropy ())
  ; now
  }
;;

let deployment_id t = t.deployment_id

let outcome_of = function
  | Ok _ -> Sol_cli_deployment.Applied
  | Error _ -> Sol_cli_deployment.Apply_failed
;;

let record ~ctx ~target plan (t : t) outcome =
  match
    Sol_cli_deployment_store.record
      ~ctx
      (Sol_cli_deployment.of_plan
         ~deployment_id:t.deployment_id
         ~now:t.now
         ~git_commit:(Sol_cli_deployment.git_commit ())
         ~git_dirty:(Sol_cli_deployment.git_dirty ())
         ~actor:(Sys.getenv_opt "SOL_ACTOR")
         ~target
         ~outcome
         plan)
  with
  | Ok () -> true
  | Error msg ->
    Printf.eprintf "warning: could not record deployment: %s\n%!" msg;
    false
;;
