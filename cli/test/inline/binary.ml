let candidates () =
  let dir = Filename.dirname Sys.executable_name in
  List.init 6 (fun n ->
    let rec up k path = if k = 0 then path else up (k - 1) (Filename.dirname path) in
    Filename.concat (up n dir) "cli/bin/main.exe")
;;

let%test "locates the built binary" =
  let found = List.filter Sys.file_exists (candidates ()) in
  Windtrap.equal Windtrap.int 1 (List.length found);
  Windtrap.equal Windtrap.string "hello" "hello"
;;

let%test "runs the built binary" =
  match List.filter Sys.file_exists (candidates ()) with
  | [] -> Windtrap.equal Windtrap.string "a binary" "none found"
  | binary :: _ -> (
    match Sol_cli_process.run (Sol_cli_process.cmd [ binary; "--help" ]) with
    | Ok output -> Windtrap.equal Windtrap.bool true (String.length output.stdout > 0)
    | Error e -> Windtrap.equal Windtrap.string "a successful run" (Sol_cli_process.error_to_string e))
;;
