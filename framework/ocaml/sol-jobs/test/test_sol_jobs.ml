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

let test_validate_retry_policy_rejects_zero_max_attempts () =
  let policy = { Sol_jobs.default_retry_policy with max_attempts = 0 } in
  Alcotest.(check bool)
    "Error `Config"
    true
    (match Sol_jobs.For_testing.validate_retry_policy policy with
     | Error (`Config _) -> true
     | Error (`Database _) | Ok () -> false)
;;

let test_validate_workspace () =
  let ok value = Result.is_ok (Sol_jobs.For_testing.validate_workspace value) in
  Alcotest.(check bool) "a plain name is accepted" true (ok "myapp");
  Alcotest.(check bool) "dots, dashes and case are accepted" true (ok "My_App.v2-x");
  Alcotest.(check bool) "empty is refused" false (ok "");
  Alcotest.(check bool) "whitespace only is refused" false (ok "   ");
  Alcotest.(check bool) "an inner space is refused" false (ok "my app");
  Alcotest.(check bool) "a slash is refused" false (ok "my/app");
  Alcotest.(check bool) "over 63 characters is refused" false (ok (String.make 64 'a'))
;;

let test_validate_kinds () =
  let ok kinds = Result.is_ok (Sol_jobs.For_testing.validate_kinds kinds) in
  Alcotest.(check bool) "typical kinds accepted" true (ok [ "send_email"; "report.v2-x" ]);
  Alcotest.(check bool) "empty list refused" false (ok []);
  Alcotest.(check bool) "empty kind refused" false (ok [ "a"; "" ]);
  Alcotest.(check bool) "separator refused" false (ok [ "a,b" ]);
  Alcotest.(check bool) "uppercase refused" false (ok [ "SendEmail" ])
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

let test_validate_retry_policy_rejects_invalid_timings () =
  let rejected policy =
    match Sol_jobs.For_testing.validate_retry_policy policy with
    | Error (`Config _) -> true
    | Error (`Database _) | Ok () -> false
  in
  let base = Sol_jobs.default_retry_policy in
  Alcotest.(check bool)
    "negative base_delay_s"
    true
    (rejected { base with base_delay_s = -1.0 });
  Alcotest.(check bool)
    "nan base_delay_s"
    true
    (rejected { base with base_delay_s = Float.nan });
  Alcotest.(check bool)
    "infinite max_delay_s"
    true
    (rejected { base with max_delay_s = Float.infinity });
  Alcotest.(check bool)
    "negative max_delay_s"
    true
    (rejected { base with max_delay_s = -10.0 });
  Alcotest.(check bool) "jitter above 1" true (rejected { base with jitter_ratio = 2.0 });
  Alcotest.(check bool)
    "negative jitter"
    true
    (rejected { base with jitter_ratio = -0.5 });
  Alcotest.(check bool)
    "nan jitter"
    true
    (rejected { base with jitter_ratio = Float.nan });
  Alcotest.(check bool)
    "zero retry delays accepted"
    true
    (not (rejected { base with base_delay_s = 0.0; max_delay_s = 0.0 }));
  Alcotest.(check bool) "the default policy is accepted" true (not (rejected base))
;;

let test_validate_timing () =
  let accepted ~poll ~lease =
    match Sol_jobs.For_testing.validate_timing ~poll_interval_s:poll ~lease_s:lease with
    | Ok () -> true
    | Error _ -> false
  in
  Alcotest.(check bool) "defaults accepted" true (accepted ~poll:1.0 ~lease:300.0);
  Alcotest.(check bool) "zero poll refused" false (accepted ~poll:0.0 ~lease:300.0);
  Alcotest.(check bool) "negative poll refused" false (accepted ~poll:(-1.0) ~lease:300.0);
  Alcotest.(check bool) "nan poll refused" false (accepted ~poll:Float.nan ~lease:300.0);
  Alcotest.(check bool)
    "infinite poll refused"
    false
    (accepted ~poll:Float.infinity ~lease:300.0);
  Alcotest.(check bool) "zero lease refused" false (accepted ~poll:1.0 ~lease:0.0);
  Alcotest.(check bool) "negative lease refused" false (accepted ~poll:1.0 ~lease:(-5.0));
  Alcotest.(check bool) "nan lease refused" false (accepted ~poll:1.0 ~lease:Float.nan)
;;

let contains ~needle haystack =
  let n = String.length needle
  and m = String.length haystack in
  let rec go i = i + n <= m && (String.sub haystack i n = needle || go (i + 1)) in
  go 0
;;

module Email = struct
  type t = string

  let workspace = "test"
  let kind (_ : t) = "send_email"
  let kinds = [ "send_email" ]
  let encode t = t
  let decode s = Ok s
  let handle (_ : t) = Ok ()
end

module Emails = Sol_jobs.Make (Email)

let test_invalid_timing_fails_before_database_or_signals () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match
    Pg_db.create_pool
      ~url:"postgresql://127.0.0.1:1/unused"
      ~sw
      ~stdenv:(env :> Caqti_eio.stdenv)
      ()
  with
  | Error e -> Alcotest.failf "pool: %s" (Pg_error.to_string e)
  | Ok pool ->
    (match Emails.run ~env ~pool ~lease_s:0.0 () with
     | Error (`Config msg) ->
       Alcotest.(check bool) "names lease_s" true (contains ~needle:"lease_s" msg)
     | Error (`Database m) -> Alcotest.failf "expected a Config error, got Database: %s" m
     | Ok () -> Alcotest.fail "an invalid lease must not start the poller")
;;

let () =
  let open Alcotest in
  run
    "sol_jobs"
    [ ( "kinds"
      , [ test_case "validate_kinds" `Quick test_validate_kinds
        ; test_case
            "validate_workspace accepts a name and refuses the rest (BUG-115)"
            `Quick
            test_validate_workspace
        ] )
    ; ( "backoff_s"
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
        ; test_case
            "rejects nonfinite or out-of-range timing (CODEX_STYLE_AUDIT-079)"
            `Quick
            test_validate_retry_policy_rejects_invalid_timings
        ] )
    ; ( "validate_timing"
      , [ test_case
            "accepts positive, refuses nonpositive or nonfinite (CODEX_STYLE_AUDIT-079)"
            `Quick
            test_validate_timing
        ] )
    ; ( "config boundary"
      , [ test_case
            "invalid timing is Config before the pool (CODEX_STYLE_AUDIT-079)"
            `Quick
            test_invalid_timing_fails_before_database_or_signals
        ] )
    ]
;;
