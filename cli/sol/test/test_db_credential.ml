(* HARDEN-002 (run 1): the policy that stops an unusable database master password
   from reaching AWS. The live defect was an apply that created the cluster and
   then failed with "InvalidParameterValue: Invalid master password", because the
   provider module's empty default was passed straight to RDS. *)

module C = Sol_cli_db_credential

let contains haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

let check = Alcotest.(check bool)
let rds = [ "create_rds=true"; "rds_multi_az=true"; "region=us-east-1" ]

let test_no_postgres_needs_no_credential () =
  check
    "an apply that creates no Postgres proceeds"
    true
    (C.check ~provider:Sol_cli_provider.Aws ~vars:[ "create_rds=false" ] ~tf_var_env:None
     = Ok ());
  check
    "create_rds absent does not ask for a password"
    true
    (C.check ~provider:Sol_cli_provider.Aws ~vars:[ "region=us-east-1" ] ~tf_var_env:None
     = Ok ())
;;

let test_missing_credential_fails_closed () =
  match C.check ~provider:Sol_cli_provider.Aws ~vars:rds ~tf_var_env:None with
  | Ok () -> Alcotest.fail "expected a missing-credential failure"
  | Error msg ->
    check "names the environment variable" true (contains msg "TF_VAR_db_password");
    check "says it is never written out" true (contains msg "never writes it")
;;

let test_empty_environment_value_is_missing () =
  check
    "an empty TF_VAR_db_password is not a credential"
    true
    (match C.check ~provider:Sol_cli_provider.Aws ~vars:rds ~tf_var_env:(Some "   ") with
     | Error _ -> true
     | Ok () -> false)
;;

let test_environment_is_accepted () =
  check
    "TF_VAR_db_password is the accepted source"
    true
    (C.check ~provider:Sol_cli_provider.Aws ~vars:rds ~tf_var_env:(Some "s3cret-pw!")
     = Ok ())
;;

let test_command_line_password_is_refused () =
  (* The value would land in the run log, which records the terraform argv. *)
  match
    C.check
      ~provider:Sol_cli_provider.Aws
      ~vars:(rds @ [ "db_password=leaked-in-the-log" ])
      ~tf_var_env:None
  with
  | Ok () -> Alcotest.fail "expected --var to be refused"
  | Error msg ->
    check "refuses --var" true (contains msg "refusing a database master password");
    check "explains the leak" true (contains msg "run log")
;;

let test_command_line_password_is_refused_even_with_the_environment_set () =
  check
    "the argv copy is still refused when the environment also carries one"
    true
    (match
       C.check
         ~provider:Sol_cli_provider.Aws
         ~vars:(rds @ [ "db_password=leaked-in-the-log" ])
         ~tf_var_env:(Some "s3cret-pw!")
     with
     | Error _ -> true
     | Ok () -> false)
;;

(* This test used to assert the opposite, and the assertion was the defect: it
   said a GCP invocation is "unaffected" because only the AWS root was consulted,
   so every GCP target fell through to [Not_needed] and the check passed
   vacuously. GCP's root always creates its Cloud SQL instance -- there is no
   `create_rds`-shaped switch to consult -- so the credential is required
   unconditionally, which is the behaviour asserted now. *)
let test_gcp_always_needs_the_password () =
  check
    "GCP without a credential source is refused"
    true
    (Result.is_error (C.check ~provider:Sol_cli_provider.Gcp ~vars:rds ~tf_var_env:None));
  check
    "GCP with the environment is accepted"
    true
    (C.check ~provider:Sol_cli_provider.Gcp ~vars:rds ~tf_var_env:(Some "x") = Ok ());
  check
    "GCP refuses a password passed on the command line"
    true
    (Result.is_error
       (C.check
          ~provider:Sol_cli_provider.Gcp
          ~vars:([ "db_password=oops" ] @ rds)
          ~tf_var_env:(Some "x")))
;;

let test_source_reports_where_it_came_from () =
  let src = C.source ~provider:Sol_cli_provider.Aws ~vars:rds ~tf_var_env:(Some "x") in
  check "environment" true (src = C.Environment);
  let src = C.source ~provider:Sol_cli_provider.Aws ~vars:rds ~tf_var_env:None in
  check "missing" true (src = C.Missing);
  let src =
    C.source ~provider:Sol_cli_provider.Aws ~vars:[ "create_rds=false" ] ~tf_var_env:None
  in
  check "not needed" true (src = C.Not_needed);
  let src =
    C.source
      ~provider:Sol_cli_provider.Aws
      ~vars:(rds @ [ "db_password=v" ])
      ~tf_var_env:None
  in
  check "command line" true (src = C.Command_line)
;;

let () =
  Alcotest.run
    "db_credential"
    [ ( "rds master password"
      , [ Alcotest.test_case
            "no postgres needs no credential"
            `Quick
            test_no_postgres_needs_no_credential
        ; Alcotest.test_case
            "missing credential fails closed"
            `Quick
            test_missing_credential_fails_closed
        ; Alcotest.test_case
            "empty environment value is missing"
            `Quick
            test_empty_environment_value_is_missing
        ; Alcotest.test_case "environment accepted" `Quick test_environment_is_accepted
        ; Alcotest.test_case
            "command-line password refused"
            `Quick
            test_command_line_password_is_refused
        ; Alcotest.test_case
            "command-line password refused even with the environment set"
            `Quick
            test_command_line_password_is_refused_even_with_the_environment_set
        ; Alcotest.test_case
            "GCP always needs the password"
            `Quick
            test_gcp_always_needs_the_password
        ; Alcotest.test_case "source" `Quick test_source_reports_where_it_came_from
        ] )
    ]
;;
