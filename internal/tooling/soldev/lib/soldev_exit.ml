(* REFAC-137: nothing below a command's term exits (REFAC-115's rule, applied to
   soldev). A command returns [(unit, failure) result]; its Cmdliner term converts
   it to a process exit once, with [exit_on].

   [message] is [None] when the command has already printed its report (e.g.
   `check`'s "status: blocked-by-dependency") and only the exit code remains. *)
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
