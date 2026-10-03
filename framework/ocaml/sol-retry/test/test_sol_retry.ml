let bounded : Sol_retry.policy =
  { base_delay_s = 1.0; max_delay_s = 10.0; max_attempts = 3; jitter_ratio = 0.2 }
;;

let fixed : Sol_retry.policy =
  { base_delay_s = 1.0; max_delay_s = 1.0; max_attempts = -1; jitter_ratio = 0.0 }
;;

let validated policy =
  match Sol_retry.of_policy policy with
  | Ok validated -> validated
  | Error message -> Windtrap.failf "the policy was rejected: %s" message
;;

let test_run_returns_a_first_attempt_success_without_waiting () =
  Eio_mock.Backend.run_full (fun env ->
    let started = Eio.Time.now env#clock in
    let attempts = ref 0 in
    let result =
      Sol_retry.run ~clock:env#clock (validated bounded) (fun () ->
        incr attempts;
        Ok !attempts)
    in
    Windtrap.equal
      (Windtrap.result Windtrap.int Windtrap.string)
      ~msg:"the first attempt is returned"
      (Ok 1)
      result;
    Windtrap.equal Windtrap.int ~msg:"one attempt" 1 !attempts;
    Windtrap.equal
      (Windtrap.float 0.0001)
      ~msg:"no backoff before a first-attempt success"
      0.0
      (Eio.Time.now env#clock -. started))
;;

let test_run_retries_until_the_operation_succeeds () =
  Eio_mock.Backend.run_full (fun env ->
    let attempts = ref 0 in
    let result =
      Sol_retry.run ~clock:env#clock (validated bounded) (fun () ->
        incr attempts;
        if !attempts < 3 then Error "transient" else Ok !attempts)
    in
    Windtrap.equal
      (Windtrap.result Windtrap.int Windtrap.string)
      ~msg:"the third attempt succeeds"
      (Ok 3)
      result;
    Windtrap.equal Windtrap.int ~msg:"three attempts" 3 !attempts)
;;

let test_run_returns_the_last_error_when_attempts_run_out () =
  Eio_mock.Backend.run_full (fun env ->
    let attempts = ref 0 in
    let result =
      Sol_retry.run ~clock:env#clock (validated bounded) (fun () ->
        incr attempts;
        Error (Printf.sprintf "failure %d" !attempts))
    in
    Windtrap.equal
      (Windtrap.result Windtrap.int Windtrap.string)
      ~msg:"the last error is returned, not the first"
      (Error "failure 3")
      result;
    Windtrap.equal
      Windtrap.int
      ~msg:"exactly max_attempts attempts"
      bounded.max_attempts
      !attempts)
;;

let test_run_waits_the_backoff_between_attempts () =
  Eio_mock.Backend.run_full (fun env ->
    let started = Eio.Time.now env#clock in
    let attempts = ref 0 in
    let result =
      Sol_retry.run ~clock:env#clock (validated fixed) (fun () ->
        incr attempts;
        if !attempts < 3 then Error "transient" else Ok ())
    in
    Windtrap.equal
      (Windtrap.result Windtrap.unit Windtrap.string)
      ~msg:"the third attempt succeeds"
      (Ok ())
      result;
    Windtrap.equal
      (Windtrap.float 0.0001)
      ~msg:"two backoffs of exactly base_delay_s"
      (2.0 *. fixed.base_delay_s)
      (Eio.Time.now env#clock -. started))
;;

let test_run_stops_when_the_caller_is_cancelled () =
  Eio_mock.Backend.run_full (fun env ->
    let attempts = ref 0 in
    let cancelled = ref false in
    Eio.Fiber.first
      (fun () ->
         try
           ignore
             (Sol_retry.run ~clock:env#clock (validated fixed) (fun () ->
                incr attempts;
                Error "always a transient failure"))
         with
         | Eio.Cancel.Cancelled _ -> cancelled := true)
      (fun () -> Eio.Time.sleep env#clock 2.5);
    Windtrap.equal Windtrap.bool ~msg:"the retry observed cancellation" true !cancelled;
    Windtrap.equal
      Windtrap.int
      ~msg:"it stopped after the two backoffs that fit before the cancel"
      3
      !attempts)
;;

let test_run_with_unbounded_attempts_stops_at_the_first_success () =
  Eio_mock.Backend.run_full (fun env ->
    let attempts = ref 0 in
    let result =
      Sol_retry.run ~clock:env#clock (validated fixed) (fun () ->
        incr attempts;
        if !attempts < 4 then Error "transient" else Ok "done")
    in
    Windtrap.equal
      (Windtrap.result Windtrap.string Windtrap.string)
      ~msg:"unbounded attempts keep going until the operation succeeds"
      (Ok "done")
      result;
    Windtrap.equal Windtrap.int ~msg:"four attempts" 4 !attempts)
;;

let test_backoff_s_stays_within_the_jittered_envelope () =
  let policy = bounded in
  let rng = Random.State.make [| 42 |] in
  for attempt = 1 to 5 do
    let raw = policy.base_delay_s *. (2. ** Float.of_int (attempt - 1)) in
    let floor = Float.min policy.max_delay_s (raw *. (1.0 -. policy.jitter_ratio)) in
    let ceiling = Float.min policy.max_delay_s (raw *. (1.0 +. policy.jitter_ratio)) in
    for _ = 1 to 100 do
      let delay = Sol_retry.backoff_s ~rng policy ~attempt in
      Windtrap.equal
        Windtrap.bool
        ~msg:(Printf.sprintf "attempt %d stays within the jittered envelope" attempt)
        true
        (delay >= floor && delay <= ceiling)
    done
  done
;;

let test_backoff_s_caps_at_max_delay () =
  let rng = Random.State.make [| 7 |] in
  for attempt = 1 to 30 do
    let delay = Sol_retry.backoff_s ~rng bounded ~attempt in
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "attempt %d never exceeds max_delay_s" attempt)
      true
      (delay >= 0.0 && delay <= bounded.max_delay_s)
  done
;;

let test_backoff_s_is_deterministic_for_one_seed () =
  let first = Sol_retry.backoff_s ~rng:(Random.State.make [| 5 |]) bounded ~attempt:3 in
  let second = Sol_retry.backoff_s ~rng:(Random.State.make [| 5 |]) bounded ~attempt:3 in
  Windtrap.equal (Windtrap.float 0.0) ~msg:"one seed, one delay" first second
;;

let test_validate_accepts_the_vocabulary () =
  Windtrap.equal
    (Windtrap.result Windtrap.unit Windtrap.string)
    ~msg:"the default policy is valid"
    (Ok ())
    (Sol_retry.validate Sol_retry.default_policy);
  Windtrap.equal
    (Windtrap.result Windtrap.unit Windtrap.string)
    ~msg:"a negative max_attempts means unbounded"
    (Ok ())
    (Sol_retry.validate { Sol_retry.default_policy with max_attempts = -1 })
;;

let test_validate_refuses_each_invalid_field () =
  let refused ~msg policy =
    match Sol_retry.validate policy with
    | Error message ->
      Windtrap.equal Windtrap.bool ~msg:(msg ^ ": names the field") true (message <> "")
    | Ok () -> Windtrap.fail (msg ^ ": the policy must be refused")
  in
  let base = Sol_retry.default_policy in
  refused ~msg:"zero max_attempts" { base with max_attempts = 0 };
  refused ~msg:"a negative base_delay_s" { base with base_delay_s = -1.0 };
  refused ~msg:"a non-finite max_delay_s" { base with max_delay_s = Float.nan };
  refused ~msg:"a jitter_ratio above one" { base with jitter_ratio = 2.0 };
  refused ~msg:"a negative jitter_ratio" { base with jitter_ratio = -0.5 };
  refused ~msg:"a non-finite jitter_ratio" { base with jitter_ratio = Float.nan }
;;

let test_of_policy_reports_the_refusal () =
  match Sol_retry.of_policy { bounded with max_attempts = 0 } with
  | Ok _ -> Windtrap.fail "of_policy must refuse max_attempts = 0"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the refusal names the field"
      true
      (String.starts_with ~prefix:"max_attempts" message)
;;

let () =
  let open Windtrap in
  run
    "sol_retry"
    [ Windtrap.group
        "run"
        [ test
            "returns a first-attempt success without waiting"
            test_run_returns_a_first_attempt_success_without_waiting
        ; test
            "retries until the operation succeeds"
            test_run_retries_until_the_operation_succeeds
        ; test
            "returns the last error when attempts run out"
            test_run_returns_the_last_error_when_attempts_run_out
        ; test
            "waits the backoff between attempts"
            test_run_waits_the_backoff_between_attempts
        ; test
            "stops when the caller is cancelled"
            test_run_stops_when_the_caller_is_cancelled
        ; test
            "unbounded attempts stop at the first success"
            test_run_with_unbounded_attempts_stops_at_the_first_success
        ]
    ; Windtrap.group
        "backoff_s"
        [ test
            "stays within the jittered envelope"
            test_backoff_s_stays_within_the_jittered_envelope
        ; test "caps at max_delay_s" test_backoff_s_caps_at_max_delay
        ; test
            "is deterministic for one seed"
            test_backoff_s_is_deterministic_for_one_seed
        ]
    ; Windtrap.group
        "policy"
        [ test "accepts the vocabulary" test_validate_accepts_the_vocabulary
        ; test "refuses each invalid field" test_validate_refuses_each_invalid_field
        ; test "of_policy reports the refusal" test_of_policy_reports_the_refusal
        ]
    ]
;;
