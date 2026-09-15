(* FEAT-077: sol-jobs' backoff schedule mirrors kafka-eio's Kafka.Consumer.backoff_s
   exactly (same formula, same self-seeded/mutex-protected rng discipline) but is
   reimplemented independently rather than pulling kafka-eio into a Postgres-only
   library -- these tests are deliberately close copies of kafka-eio's own
   test_consumer_unit.ml backoff_s coverage, to catch the two formulas drifting
   apart. *)

let policy : Sol_jobs.retry_policy =
  { base_delay_s = 1.0; max_delay_s = 10.0; max_attempts = -1; jitter_ratio = 0.2 }
;;

let test_backoff_s_early_attempt_within_jittered_bounds () =
  let rng = Random.State.make [| 42 |] in
  let raw = policy.base_delay_s *. (2. ** Float.of_int (2 - 1)) in
  let delay = Sol_jobs.For_testing.backoff_s ~rng policy 2 in
  Alcotest.(check bool)
    "within +-20% of the raw exponential delay"
    true
    (delay >= raw *. 0.8 && delay <= raw *. 1.2)
;;

let test_backoff_s_caps_at_max_delay () =
  let rng = Random.State.make [| 7 |] in
  for attempt = 1 to 30 do
    let delay = Sol_jobs.For_testing.backoff_s ~rng policy attempt in
    Alcotest.(check bool)
      (Printf.sprintf "attempt %d never exceeds max_delay_s" attempt)
      true
      (delay <= policy.max_delay_s)
  done
;;

let test_backoff_s_never_negative () =
  let rng = Random.State.make [| 99 |] in
  for attempt = 1 to 10 do
    let delay = Sol_jobs.For_testing.backoff_s ~rng policy attempt in
    Alcotest.(check bool)
      (Printf.sprintf "attempt %d never negative" attempt)
      true
      (delay >= 0.0)
  done
;;

let test_backoff_s_deterministic_with_same_seed () =
  let delay1 = Sol_jobs.For_testing.backoff_s ~rng:(Random.State.make [| 5 |]) policy 3 in
  let delay2 = Sol_jobs.For_testing.backoff_s ~rng:(Random.State.make [| 5 |]) policy 3 in
  Alcotest.(check (float 0.0)) "same seed, same delay" delay1 delay2
;;

let test_backoff_s_no_jitter_when_ratio_zero () =
  let policy = { policy with jitter_ratio = 0.0 } in
  let rng = Random.State.make [| 1 |] in
  Alcotest.(check (float 0.0001))
    "exact exponential delay"
    2.0
    (Sol_jobs.For_testing.backoff_s ~rng policy 2)
;;

(* FEAT-077: run() must fail fast on an invalid retry_policy (max_attempts = 0)
   before ever touching Postgres or entering the claim loop -- same "discover
   the problem before the first job, not after" discipline FEAT-078 applied to
   sol-worker's mandatory retry_strategy. Testing the extracted
   [validate_retry_policy] directly (rather than a full [Make(_).run] call)
   avoids needing a live Postgres pool just to exercise this check. *)
let test_validate_retry_policy_rejects_zero_max_attempts () =
  let policy = { Sol_jobs.default_retry_policy with max_attempts = 0 } in
  Alcotest.(check bool)
    "Error `Config"
    true
    (match Sol_jobs.For_testing.validate_retry_policy policy with
     | Error (`Config _) -> true
     | Ok () -> false)
;;

let test_validate_retry_policy_accepts_positive_and_negative () =
  let accepts max_attempts =
    match
      Sol_jobs.For_testing.validate_retry_policy
        { Sol_jobs.default_retry_policy with max_attempts }
    with
    | Ok () -> true
    | Error _ -> false
  in
  Alcotest.(check bool) "positive max_attempts accepted" true (accepts 5);
  Alcotest.(check bool) "negative (unlimited) max_attempts accepted" true (accepts (-1))
;;

let () =
  let open Alcotest in
  run
    "sol_jobs"
    [ ( "backoff_s"
      , [ test_case
            "early attempt within jittered bounds"
            `Quick
            test_backoff_s_early_attempt_within_jittered_bounds
        ; test_case "caps at max delay" `Quick test_backoff_s_caps_at_max_delay
        ; test_case "never negative" `Quick test_backoff_s_never_negative
        ; test_case
            "deterministic with the same seed"
            `Quick
            test_backoff_s_deterministic_with_same_seed
        ; test_case
            "no jitter when jitter_ratio is 0"
            `Quick
            test_backoff_s_no_jitter_when_ratio_zero
        ] )
    ; ( "validate_retry_policy"
      , [ test_case
            "rejects max_attempts = 0"
            `Quick
            test_validate_retry_policy_rejects_zero_max_attempts
        ; test_case
            "accepts positive and negative max_attempts"
            `Quick
            test_validate_retry_policy_accepts_positive_and_negative
        ] )
    ]
;;
