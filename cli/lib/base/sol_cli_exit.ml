let or_exit = function
  | Ok x -> x
  | Error msg ->
    Printf.eprintf "error: %s\n%!" msg;
    exit 1
;;

let or_exit_with to_string r = or_exit (Result.map_error to_string r)

type failure =
  { text : string
  ; code : int
  }

let error ?(code = 1) msg = { text = "error: " ^ msg; code }
let failure ?(code = 1) text = { text; code }

let exit_on = function
  | Ok () -> ()
  | Error { text; code } ->
    (* What the command printed comes before why it failed. *)
    flush stdout;
    Printf.eprintf "%s\n%!" text;
    exit code
;;
