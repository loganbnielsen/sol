let unwrap = function
  | Ok value -> value
  | Error message -> Windtrap.fail message
;;

let test_bounded_command_bytes () =
  let sol = Cli_binary.path () in
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
             (Sol_cli_process.cmd ~cwd:root [ "sh"; "-c"; command ])
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
         | Error error -> Windtrap.fail (Sol_cli_process.error_to_string error)
       in
       let check = run [ "check" ] in
       Windtrap.equal Windtrap.string ~msg:"check stdout" "sol check: ok\n" check.stdout;
       Windtrap.equal Windtrap.string ~msg:"check stderr" "" check.stderr)
;;

let%test "command bytes: check" = test_bounded_command_bytes ()
