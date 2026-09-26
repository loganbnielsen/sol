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
let reported ?(code = 1) () = { text = ""; code }
let of_msg r = Result.map_error error r
let of_error to_string r = Result.map_error (fun e -> error (to_string e)) r

let exit_on = function
  | Ok () -> ()
  | Error { text; code } ->
    (* What the command printed comes before why it failed. *)
    flush stdout;
    if text <> "" then Printf.eprintf "%s\n%!" text;
    exit code
;;
