type failure =
  { message : string option
  ; code : int
  }

let error ?(code = 1) message = Error { message = Some message; code }
let reported ?(code = 1) () = Error { message = None; code }

let exit_on = function
  | Ok () -> ()
  | Error { message; code } ->
    Option.iter prerr_endline message;
    exit code
;;
