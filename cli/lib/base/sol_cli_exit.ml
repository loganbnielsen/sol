let or_exit = function
  | Ok x -> x
  | Error msg ->
    Printf.eprintf "error: %s\n%!" msg;
    exit 1
;;

let or_exit_with to_string r = or_exit (Result.map_error to_string r)
