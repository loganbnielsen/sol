let test_outcome_of () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"Ok is Applied"
    true
    (Sol_cli_deployment_attempt.outcome_of (Ok 1) = Sol_cli_deployment.Applied);
  Windtrap.equal
    Windtrap.bool
    ~msg:"Error is Apply_failed"
    true
    (Sol_cli_deployment_attempt.outcome_of (Error "boom")
     = Sol_cli_deployment.Apply_failed)
;;

module A = Sol_cli_deployment_attempt

let show = function
  | None -> "none"
  | Some (actor : A.actor) -> actor.name ^ "|" ^ actor.source
;;

let test_pick_prefers_an_observed_claim_over_the_override () =
  Windtrap.equal
    Windtrap.string
    ~msg:"a CI claim outranks git and the override"
    "ci-user|ci:github-actions"
    (show
       (A.pick
          ~ci:(Some ("ci:github-actions", "ci-user"))
          ~git:(Some "dev@example.test")
          ~override:(Some "typed-by-hand")));
  Windtrap.equal
    Windtrap.string
    ~msg:"git stands in when the CI environment says nothing"
    "dev@example.test|git:local"
    (show
       (A.pick ~ci:None ~git:(Some "dev@example.test") ~override:(Some "typed-by-hand")));
  Windtrap.equal
    Windtrap.string
    ~msg:"the override is the last resort, and is labelled as one"
    "typed-by-hand|override:env"
    (show (A.pick ~ci:None ~git:None ~override:(Some "typed-by-hand")));
  Windtrap.equal
    Windtrap.string
    ~msg:"no observation means no actor, never an invented one"
    "none"
    (show (A.pick ~ci:None ~git:None ~override:None))
;;

let test_start_mints_an_id () =
  let attempt = Sol_cli_deployment_attempt.start () in
  let id = Sol_cli_deployment_attempt.deployment_id attempt in
  Windtrap.equal
    Windtrap.bool
    ~msg:"id is non-empty"
    true
    (String.length (Sol_cli_deployment_id.to_string id) > 0)
;;

let%test "attempt: outcome_of" = test_outcome_of ()

let%test "attempt: provenance precedence" =
  test_pick_prefers_an_observed_claim_over_the_override ()
;;

let%test "attempt: start mints an id" = test_start_mints_an_id ()
