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

let record ~ctx ~target ?release_id plan (t : t) outcome =
  match
    Sol_cli_deployment_store.record
      ~ctx
      (Sol_cli_deployment.of_plan
         ?release_id
         ~deployment_id:t.deployment_id
         ~now:t.now
         ~git_commit:(Sol_cli_deployment.git_commit ())
         ~git_dirty:(Sol_cli_deployment.git_dirty ())
         ~actor:(Sol_cli_string.env "SOL_ACTOR")
         ~target
         ~outcome
         plan)
  with
  | Ok () -> true
  | Error msg ->
    Sol_cli_report.warn "warning: could not record deployment: %s" msg;
    false
;;
