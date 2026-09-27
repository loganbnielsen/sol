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
    flush stdout;
    if text <> ""
    then
      Printf.eprintf
        "%s%s%!"
        text
        (if String.ends_with ~suffix:"\n" text then "" else "\n");
    exit code
;;
