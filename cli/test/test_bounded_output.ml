let unwrap = function
  | Ok value -> value
  | Error message -> Alcotest.fail message
;;

let test_bounded_command_bytes () =
  let executable =
    if Filename.is_relative Sys.executable_name
    then Filename.concat (Sys.getcwd ()) Sys.executable_name
    else Sys.executable_name
  in
  let sol =
    Filename.concat (Filename.dirname (Filename.dirname executable)) "bin/main.exe"
  in
  let root = Filename.temp_dir "sol-bounded-output-" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       let unit_dir = Filename.concat root "app/payments/charge_svc" in
       unwrap (Sol_cli_fs.mkdir_p unit_dir);
       unwrap
         (Sol_cli_fs.write_atomic
            (Filename.concat unit_dir "Dockerfile")
            "FROM scratch\n");
       unwrap (Sol_cli_fs.write_atomic (Filename.concat unit_dir "sol.toml") "");
       unwrap
         (Sol_cli_fs.write_atomic
            (Filename.concat root "sol.yml")
            "project: demo\nservices:\n  charge_svc:\n    language: ocaml\n");
       let target_dir = Filename.concat root "sol" in
       unwrap (Sol_cli_fs.mkdir_p target_dir);
       unwrap
         (Sol_cli_fs.write_atomic
            (Filename.concat target_dir "environments.yml")
            "prod:\n\
            \  targets:\n\
            \    aws/us-east-1:\n\
            \      alert_receiver_type: webhook\n\
            \      alert_receiver_url: https://hooks.example.test/x\n\
            \      alert_owner: ops@example.test\n\
            \      alert_runbook_url: https://runbooks.example.test/x\n");
       let curl = Filename.concat root "curl" in
       unwrap (Sol_cli_fs.write_atomic curl "#!/bin/sh\nexit 0\n");
       Unix.chmod curl 0o755;
       let path = root ^ ":" ^ Option.value (Sys.getenv_opt "PATH") ~default:"" in
       let run_result args =
         let stdout_path = Filename.concat root "stdout" in
         let stderr_path = Filename.concat root "stderr" in
         let command =
           String.concat " " (List.map Filename.quote (sol :: args))
           ^ " > "
           ^ Filename.quote stdout_path
           ^ " 2> "
           ^ Filename.quote stderr_path
         in
         let captured =
           Sol_cli_process.run
             ~echo:false
             (Sol_cli_process.cmd ~cwd:root ~env:[ "PATH", path ] [ "sh"; "-c"; command ])
         in
         let read path = In_channel.with_open_bin path In_channel.input_all in
         match captured with
         | Ok _ ->
           Sol_cli_process.completed
             ~exit_code:0
             ~stdout:(read stdout_path)
             ~stderr:(read stderr_path)
         | Error (Non_zero failure) ->
           Sol_cli_process.completed
             ~exit_code:failure.exit_code
             ~stdout:(read stdout_path)
             ~stderr:(read stderr_path)
         | Error error -> Error error
       in
       let run args =
         match run_result args with
         | Ok output -> output
         | Error error -> Alcotest.fail (Sol_cli_process.error_to_string error)
       in
       let check = run [ "check" ] in
       Alcotest.(check string) "check stdout" "sol check: ok\n" check.stdout;
       Alcotest.(check string) "check stderr" "" check.stderr;
       let alert = run [ "alert"; "test"; "--target"; "prod/aws/us-east-1" ] in
       Alcotest.(check string)
         "alert stdout"
         "Sending a synthetic alert through http://127.0.0.1:9093/api/v2/alerts ...\n\
          Alertmanager accepted the synthetic alert.\n\n\
          This proves the route is configured and reachable. Confirm the named owner \
          received and acknowledged it: that delivered-and-acknowledged result is the \
          HARDEN-002 evidence, not this command's exit status.\n"
         alert.stdout;
       Alcotest.(check string) "alert stderr" "" alert.stderr;
       unwrap
         (Sol_cli_fs.write_atomic curl "#!/bin/sh\necho synthetic-failure >&2\nexit 7\n");
       Unix.chmod curl 0o755;
       match run_result [ "alert"; "test"; "--target"; "prod/aws/us-east-1" ] with
       | Error (Non_zero failure) ->
         Alcotest.(check int) "rejected alert exit" 1 failure.exit_code;
         Alcotest.(check string)
           "rejected alert stdout"
           "Sending a synthetic alert through http://127.0.0.1:9093/api/v2/alerts ...\n"
           failure.stdout;
         Alcotest.(check string)
           "rejected alert stderr"
           "error: Alertmanager rejected the synthetic alert (curl exit 7).\n\
            synthetic-failure\n\
            Is the port-forward up? e.g. `kubectl -n monitoring port-forward \
            svc/prometheus-alertmanager 9093:9093`.\n"
           failure.stderr
       | _ -> Alcotest.fail "rejected alert must fail")
;;

let () =
  Alcotest.run
    "bounded output"
    [ ( "command bytes"
      , [ Alcotest.test_case "check and accepted alert" `Quick test_bounded_command_bytes
        ] )
    ]
;;
