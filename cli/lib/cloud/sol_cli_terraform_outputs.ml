type value =
  | Text of string
  | Texts of string list
  | Null

let shown (name, output) =
  match output with
  | `Assoc fields ->
    let sensitive =
      match List.assoc_opt "sensitive" fields with
      | Some (`Bool b) -> b
      | _ -> true
    in
    if sensitive
    then None
    else (
      match List.assoc_opt "value" fields with
      | Some (`String v) -> Some (name, Text v)
      | Some (`List items) ->
        (match
           List.filter_map
             (function
               | `String s -> Some s
               | _ -> None)
             items
         with
         | [] -> None
         | strings -> Some (name, Texts strings))
      | Some `Null -> Some (name, Null)
      | _ -> None)
  | _ -> None
;;

let displayable json =
  match Yojson.Safe.from_string json with
  | `Assoc outputs -> Ok (List.filter_map shown outputs)
  | _ -> Ok []
  | exception Yojson.Json_error msg -> Error msg
;;

let line (name, value) =
  match value with
  | Text v -> Printf.sprintf "  %-28s  %s" name v
  | Texts vs -> Printf.sprintf "  %-28s  [%s]" name (String.concat ", " vs)
  | Null -> Printf.sprintf "  %-28s  (none)" name
;;
