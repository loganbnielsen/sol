let dir =
  match Sol_cli_string.env "XDG_DATA_HOME" with
  | Some d -> Filename.concat d "sol"
  | None ->
    (match Sol_cli_string.env "HOME" with
     | Some h -> Filename.concat h ".local/share/sol"
     | None -> Filename.concat (Sys.getcwd ()) ".sol")
;;

let ensure () = Sol_cli_fs.mkdir_p dir
let pid_file name = Printf.sprintf "%s/pf-%s.pid" dir name
let log_file name = Printf.sprintf "/tmp/sol-pf-%s.log" name
let record_suffix = ".forward"
let record_file name = Printf.sprintf "%s/pf-%s%s" dir name record_suffix
let lock_file name = Printf.sprintf "%s/pf-%s.lock" dir name
