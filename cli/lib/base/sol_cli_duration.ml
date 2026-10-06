(* Operational duration overrides, expressed in seconds.

   An override is optional: when it is unset or blank the caller's documented
   default applies. Any value that is present must be a finite non-negative
   number of seconds. A malformed, negative, NaN or infinite value is refused
   rather than silently replaced, so an operator's bad input can never select an
   unbounded wait or a policy other than the one requested. *)
let env_seconds ~name ~default =
  match Sol_cli_string.env name with
  | None -> Ok default
  | Some raw ->
    (match float_of_string_opt raw with
     | Some seconds when Float.is_finite seconds && seconds >= 0. -> Ok seconds
     | _ ->
       Error (Printf.sprintf "%s=%S is not a non-negative number of seconds" name raw))
;;
