let text =
  let parse s =
    match String.trim s with
    | "" -> Error "must not be blank"
    | s -> Ok s
  in
  Cmdliner.Arg.conv' ~docv:"TEXT" (parse, Format.pp_print_string)
;;
