type t =
  { deployment_id : Sol_cli_deployment_id.t
  ; now : float
  }

type actor =
  { name : string
  ; source : string
  }

let ci_sources = [ "GITHUB_ACTOR", "ci:github-actions"; "GITLAB_USER_LOGIN", "ci:gitlab" ]

let pick ~ci ~git ~override =
  match ci with
  | Some (source, name) -> Some { name; source }
  | None ->
    (match git with
     | Some email -> Some { name = email; source = "git:local" }
     | None ->
       (match override with
        | Some name -> Some { name; source = "override:env" }
        | None -> None))
;;

let detect () =
  let git_email () =
    match Sol_cli_process.run (Sol_cli_process.cmd [ "git"; "config"; "user.email" ]) with
    | Ok output -> Sol_cli_string.non_blank output.stdout
    | Error _ -> None
  in
  let ci =
    List.find_map
      (fun (variable, source) ->
         Option.map (fun name -> source, name) (Sol_cli_string.env variable))
      ci_sources
  in
  pick ~ci ~git:(git_email ()) ~override:(Sol_cli_string.env "SOL_ACTOR")
;;

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
  let actor = detect () in
  match
    Sol_cli_deployment_store.record
      ~ctx
      (Sol_cli_deployment.of_plan
         ?release_id
         ~deployment_id:t.deployment_id
         ~now:t.now
         ~git_commit:(Sol_cli_deployment.git_commit ())
         ~git_dirty:(Sol_cli_deployment.git_dirty ())
         ~actor:(Option.map (fun (a : actor) -> a.name) actor)
         ~actor_source:(Option.map (fun (a : actor) -> a.source) actor)
         ~target
         ~outcome
         plan)
  with
  | Ok () -> true
  | Error msg ->
    Sol_cli_report.warn "warning: could not record deployment: %s" msg;
    false
;;
