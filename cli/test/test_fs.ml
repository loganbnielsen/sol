let check_bool = Alcotest.(check bool)

let in_temp f =
  let root = Filename.temp_dir "sol-fs-" "" in
  Fun.protect ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root)) (fun () -> f root)
;;

let write path text = Out_channel.with_open_bin path (fun oc -> output_string oc text)
let read path = In_channel.with_open_bin path In_channel.input_all

let test_remove_if_present () =
  in_temp (fun root ->
    let file = Filename.concat root "f" in
    write file "x";
    check_bool
      "present is removed"
      true
      (Result.is_ok (Sol_cli_fs.remove_if_present file));
    check_bool "gone" false (Sys.file_exists file);
    check_bool "absent is Ok" true (Result.is_ok (Sol_cli_fs.remove_if_present file));
    check_bool
      "a directory is an Error"
      true
      (Result.is_error (Sol_cli_fs.remove_if_present root)))
;;

let test_unremovable_is_an_error () =
  in_temp (fun root ->
    let dir = Filename.concat root "locked" in
    Unix.mkdir dir 0o755;
    write (Filename.concat dir "f") "x";
    Unix.chmod dir 0o555;
    let result = Sol_cli_fs.remove_if_present (Filename.concat dir "f") in
    Unix.chmod dir 0o755;
    check_bool
      "a permission failure is reported, not swallowed"
      true
      (Result.is_error result))
;;

let test_remove_tree () =
  in_temp (fun root ->
    let tree = Filename.concat root "t" in
    Sol_cli_fs.mkdir_p (Filename.concat tree "a/b") |> Result.get_ok;
    write (Filename.concat tree "a/b/f") "x";
    Unix.symlink "/" (Filename.concat tree "link-to-root");
    check_bool "removed" true (Result.is_ok (Sol_cli_fs.remove_tree tree));
    check_bool "gone" false (Sys.file_exists tree);
    check_bool "a symlink was not followed" true (Sys.file_exists "/etc");
    check_bool "absent is Ok" true (Result.is_ok (Sol_cli_fs.remove_tree tree)))
;;

let test_write_atomic () =
  in_temp (fun root ->
    let path = Filename.concat root "f" in
    Sol_cli_fs.write_atomic ~perm:0o600 path "one" |> Result.get_ok;
    Sol_cli_fs.write_atomic ~perm:0o600 path "two" |> Result.get_ok;
    Alcotest.(check string) "the last write" "two" (read path);
    Alcotest.(check int) "the mode asked for" 0o600 (Unix.stat path).st_perm;
    Alcotest.(check (list string))
      "no temporary file left behind"
      [ "f" ]
      (Array.to_list (Sys.readdir root)))
;;

let test_with_temp_file () =
  let seen = ref "" in
  let result =
    Sol_cli_fs.with_temp_file ~prefix:"sol-fs-" ~suffix:".txt" "content" (fun path ->
      seen := path;
      read path)
  in
  Alcotest.(check (result string string)) "f read the content" (Ok "content") result;
  check_bool "removed afterwards" false (Sys.file_exists !seen)
;;

let test_copy_tree () =
  in_temp (fun root ->
    let src = Filename.concat root "src" in
    Sol_cli_fs.mkdir_p (Filename.concat src "app/_build") |> Result.get_ok;
    Sol_cli_fs.mkdir_p (Filename.concat src ".git") |> Result.get_ok;
    write (Filename.concat src "app/main.ml") "let () = ()";
    write (Filename.concat src "app/run.sh") "#!/bin/sh";
    Unix.chmod (Filename.concat src "app/run.sh") 0o755;
    write (Filename.concat src "app/_build/junk") "x";
    write (Filename.concat src "outside") "followed";
    Unix.symlink (Filename.concat src "outside") (Filename.concat src "app/link");
    let dst = Filename.concat root "dst" in
    Sol_cli_fs.copy_tree ~exclude:[ "_build"; ".git" ] ~src ~dst |> Result.get_ok;
    Alcotest.(check string)
      "a file"
      "let () = ()"
      (read (Filename.concat dst "app/main.ml"));
    Alcotest.(check int)
      "its mode"
      0o755
      (Unix.stat (Filename.concat dst "app/run.sh")).st_perm;
    Alcotest.(check string)
      "a symlink is followed"
      "followed"
      (read (Filename.concat dst "app/link"));
    check_bool
      "_build excluded"
      false
      (Sys.file_exists (Filename.concat dst "app/_build"));
    check_bool ".git excluded" false (Sys.file_exists (Filename.concat dst ".git")))
;;

let test_spawn () =
  let child =
    Sol_cli_process.spawn (Sol_cli_process.cmd [ "sleep"; "30" ]) |> Result.get_ok
  in
  check_bool
    "running"
    true
    (match Unix.kill (Sol_cli_process.pid child) 0 with
     | () -> true
     | exception Unix.Unix_error _ -> false);
  Sol_cli_process.stop child;
  let rec reaped attempts =
    attempts > 0
    &&
    match Unix.waitpid [ Unix.WNOHANG ] (Sol_cli_process.pid child) with
    | 0, _ ->
      Unix.sleepf 0.05;
      reaped (attempts - 1)
    | _ -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  check_bool "stopped" true (reaped 100);
  check_bool
    "a missing program is a spawn failure"
    true
    (match Sol_cli_process.spawn (Sol_cli_process.cmd [ "/nonexistent-xyz" ]) with
     | Error (Sol_cli_process.Spawn_failed _) -> true
     | _ -> false)
;;

let () =
  Alcotest.run
    "fs"
    [ ( "REFAC-134"
      , [ Alcotest.test_case "remove_if_present" `Quick test_remove_if_present
        ; Alcotest.test_case
            "an unremovable file is an error"
            `Quick
            test_unremovable_is_an_error
        ; Alcotest.test_case "remove_tree" `Quick test_remove_tree
        ; Alcotest.test_case "write_atomic" `Quick test_write_atomic
        ; Alcotest.test_case "with_temp_file" `Quick test_with_temp_file
        ; Alcotest.test_case "copy_tree" `Quick test_copy_tree
        ; Alcotest.test_case "spawn" `Quick test_spawn
        ] )
    ]
;;
