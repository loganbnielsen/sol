let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

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
    Windtrap.equal Windtrap.string ~msg:"the last write" "two" (read path);
    Windtrap.equal Windtrap.int ~msg:"the mode asked for" 0o600 (Unix.stat path).st_perm;
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"no temporary file left behind"
      [ "f" ]
      (Array.to_list (Sys.readdir root)))
;;

let test_read_file () =
  in_temp (fun root ->
    let path = Filename.concat root "f" in
    write path "line one\nline two\n";
    Windtrap.equal
      (Windtrap.result Windtrap.string Windtrap.string)
      ~msg:"reads the exact bytes, with no newline translation"
      (Ok "line one\nline two\n")
      (Sol_cli_fs.read_file path);
    check_bool
      "read_file_opt reads the same bytes"
      true
      (Sol_cli_fs.read_file_opt path = Some "line one\nline two\n");
    check_bool
      "a missing file is an Error that names the path"
      true
      (match Sol_cli_fs.read_file (Filename.concat root "absent") with
       | Error message -> Sol_cli_string.contains ~needle:"absent" message
       | Ok _ -> false);
    check_bool
      "read_file_opt is None for a missing file"
      true
      (Option.is_none (Sol_cli_fs.read_file_opt (Filename.concat root "absent"))))
;;

let test_with_temp_file () =
  let seen = ref "" in
  let result =
    Sol_cli_fs.with_temp_file ~prefix:"sol-fs-" ~suffix:".txt" "content" (fun path ->
      seen := path;
      read path)
  in
  Windtrap.equal
    (Windtrap.result Windtrap.string Windtrap.string)
    ~msg:"f read the content"
    (Ok "content")
    result;
  check_bool "removed afterwards" false (Sys.file_exists !seen)
;;

let is_symlink path = (Unix.lstat path).Unix.st_kind = Unix.S_LNK

let test_copy_tree () =
  in_temp (fun root ->
    let src = Filename.concat root "src" in
    Sol_cli_fs.mkdir_p (Filename.concat src "app/_build") |> Result.get_ok;
    Sol_cli_fs.mkdir_p (Filename.concat src ".git") |> Result.get_ok;
    write (Filename.concat src "app/main.ml") "let () = ()";
    write (Filename.concat src "app/run.sh") "#!/bin/sh";
    Unix.chmod (Filename.concat src "app/run.sh") 0o755;
    write (Filename.concat src "app/_build/junk") "x";
    let dst = Filename.concat root "dst" in
    Sol_cli_fs.copy_tree ~exclude:[ "_build"; ".git" ] ~src ~dst |> Result.get_ok;
    Windtrap.equal
      Windtrap.string
      ~msg:"a file"
      "let () = ()"
      (read (Filename.concat dst "app/main.ml"));
    Windtrap.equal
      Windtrap.int
      ~msg:"its mode"
      0o755
      (Unix.stat (Filename.concat dst "app/run.sh")).st_perm;
    check_bool
      "_build excluded"
      false
      (Sys.file_exists (Filename.concat dst "app/_build"));
    check_bool ".git excluded" false (Sys.file_exists (Filename.concat dst ".git")))
;;

let test_copy_tree_preserves_symlinks () =
  in_temp (fun root ->
    let src = Filename.concat root "src" in
    Sol_cli_fs.mkdir_p (Filename.concat src "app") |> Result.get_ok;
    write (Filename.concat src "app/main.ml") "main";
    let outside_file = Filename.concat root "outside-secret" in
    write outside_file "outside content";
    let outside_dir = Filename.concat root "outside-dir" in
    Sol_cli_fs.mkdir_p outside_dir |> Result.get_ok;
    write (Filename.concat outside_dir "child") "external child";
    Unix.symlink outside_file (Filename.concat src "app/external-file");
    Unix.symlink outside_dir (Filename.concat src "app/external-dir");
    Unix.symlink
      (Filename.concat src "does-not-exist")
      (Filename.concat src "app/dangling");
    Unix.symlink ".." (Filename.concat src "app/ancestor");
    let dst = Filename.concat root "dst" in
    (match Sol_cli_fs.copy_tree ~exclude:[] ~src ~dst with
     | Ok () -> ()
     | Error e -> Windtrap.failf "copy_tree failed: %s" e);
    let link name = Filename.concat (Filename.concat dst "app") name in
    check_bool
      "external file link stays a link (contents not imported)"
      true
      (is_symlink (link "external-file"));
    Windtrap.equal
      Windtrap.string
      ~msg:"external file target preserved"
      outside_file
      (Unix.readlink (link "external-file"));
    check_bool
      "external directory link stays a link (not recursed)"
      true
      (is_symlink (link "external-dir"));
    Windtrap.equal
      Windtrap.string
      ~msg:"external directory target preserved"
      outside_dir
      (Unix.readlink (link "external-dir"));
    check_bool "dangling link preserved" true (is_symlink (link "dangling"));
    check_bool "dangling link stays dangling" false (Sys.file_exists (link "dangling"));
    check_bool
      "ancestor cycle preserved without recursing"
      true
      (is_symlink (link "ancestor"));
    Windtrap.equal
      Windtrap.string
      ~msg:"regular-file positive control"
      "main"
      (read (link "main.ml")))
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

let%test "REFAC-134: remove_if_present" = test_remove_if_present ()
let%test "REFAC-134: an unremovable file is an error" = test_unremovable_is_an_error ()
let%test "REFAC-134: remove_tree" = test_remove_tree ()
let%test "REFAC-134: write_atomic" = test_write_atomic ()
let%test "CODE_LAYER-026: read_file and read_file_opt" = test_read_file ()
let%test "REFAC-134: with_temp_file" = test_with_temp_file ()
let%test "REFAC-134: copy_tree" = test_copy_tree ()

let%test "REFAC-134: copy_tree preserves symlinks (BUG-075)" =
  test_copy_tree_preserves_symlinks ()
;;

let%test "REFAC-134: spawn" = test_spawn ()
