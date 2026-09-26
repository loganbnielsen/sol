let ptime seconds =
  match Ptime.of_float_s seconds with
  | Some t -> t
  | None ->
    invalid_arg (Printf.sprintf "Sol_cli_time: %f is not a representable time" seconds)
;;

let rfc3339 seconds = Ptime.to_rfc3339 ~tz_offset_s:0 (ptime seconds)

let compact_with ~t ~z seconds =
  let (year, month, day), ((hour, minute, second), _) =
    Ptime.to_date_time (ptime seconds)
  in
  Printf.sprintf "%04d%02d%02d%c%02d%02d%02d%c" year month day t hour minute second z
;;

let compact = compact_with ~t:'T' ~z:'Z'
let compact_lower = compact_with ~t:'t' ~z:'z'
