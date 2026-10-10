type t = (string * string) list

open Result.Syntax

let valid_key key =
  let valid_char = function
    | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  String.length key > 0
  && key.[0] >= 'A'
  && key.[0] <= 'Z'
  && String.for_all valid_char key
;;

let trim = String.trim

let parse_value ~source ~line value =
  let value = trim value in
  let length = String.length value in
  if String.contains value '\000'
  then Error (Printf.sprintf "%s:%d: values may not contain NUL characters" source line)
  else if length = 0
  then Ok ""
  else (
    match value.[0], value.[length - 1] with
    | ('\'' | '"'), quote when Char.equal quote value.[0] ->
      if length < 2
      then Error (Printf.sprintf "%s:%d: unterminated quoted value" source line)
      else Ok (String.sub value 1 (length - 2))
    | ('\'' | '"'), _ ->
      Error (Printf.sprintf "%s:%d: unterminated quoted value" source line)
    | _ -> Ok value)
;;

let parse ?(source = "secret input") contents =
  let lines = String.split_on_char '\n' contents in
  let rec loop line_no seen = function
    | [] -> Ok (List.rev seen)
    | line :: rest ->
      let trimmed = trim line in
      if String.equal trimmed "" || String.starts_with ~prefix:"#" trimmed
      then loop (line_no + 1) seen rest
      else (
        match String.index_opt line '=' with
        | None -> Error (Printf.sprintf "%s:%d: expected KEY=value" source line_no)
        | Some equals ->
          let key = trim (String.sub line 0 equals) in
          let raw_value =
            String.sub line (equals + 1) (String.length line - equals - 1)
          in
          if not (valid_key key)
          then
            Error
              (Printf.sprintf
                 "%s:%d: invalid environment key %S (use uppercase letters, digits, and \
                  underscores)"
                 source
                 line_no
                 key)
          else if List.mem_assoc key seen
          then Error (Printf.sprintf "%s:%d: duplicate key %s" source line_no key)
          else (
            match parse_value ~source ~line:line_no raw_value with
            | Error _ as error -> error
            | Ok value -> loop (line_no + 1) ((key, value) :: seen) rest))
  in
  loop 1 [] lines
;;

let unit_file ~root ~unit_address =
  match String.split_on_char '/' unit_address with
  | [ domain; unit ] when domain <> "" && unit <> "" ->
    let valid_char = function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
      | _ -> false
    in
    if not (String.for_all valid_char domain && String.for_all valid_char unit)
    then Error (Printf.sprintf "invalid unit address %S" unit_address)
    else (
      let relative =
        Filename.concat "sol/secrets.local" (Filename.concat domain (unit ^ ".env"))
      in
      Ok (Filename.concat root relative, relative))
  | _ ->
    Error (Printf.sprintf "invalid unit address %S (expected domain/unit)" unit_address)
;;

let load ~root ~unit_address =
  let* path, relative = unit_file ~root ~unit_address in
  if not (Sys.file_exists path)
  then Ok []
  else (
    match In_channel.with_open_bin path In_channel.input_all with
    | contents -> parse ~source:relative contents
    | exception Sys_error _ -> Error ("could not read " ^ relative))
;;
