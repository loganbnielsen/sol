type t = (string * string) list

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

let parse_value ~line value =
  let value = trim value in
  let length = String.length value in
  if String.contains value '\000'
  then Error (Printf.sprintf ".env.local:%d: values may not contain NUL characters" line)
  else if length = 0
  then Ok ""
  else (
    match value.[0], value.[length - 1] with
    | ('\'' | '"'), quote when Char.equal quote value.[0] ->
      if length < 2
      then Error (Printf.sprintf ".env.local:%d: unterminated quoted value" line)
      else Ok (String.sub value 1 (length - 2))
    | ('\'' | '"'), _ ->
      Error (Printf.sprintf ".env.local:%d: unterminated quoted value" line)
    | _ -> Ok value)
;;

let parse contents =
  let lines = String.split_on_char '\n' contents in
  let rec loop line_no seen = function
    | [] -> Ok (List.rev seen)
    | line :: rest ->
      let trimmed = trim line in
      if String.equal trimmed "" || String.starts_with ~prefix:"#" trimmed
      then loop (line_no + 1) seen rest
      else (
        match String.index_opt line '=' with
        | None -> Error (Printf.sprintf ".env.local:%d: expected KEY=value" line_no)
        | Some equals ->
          let key = trim (String.sub line 0 equals) in
          let raw_value =
            String.sub line (equals + 1) (String.length line - equals - 1)
          in
          if not (valid_key key)
          then
            Error
              (Printf.sprintf
                 ".env.local:%d: invalid environment key %S (use uppercase letters, \
                  digits, and underscores)"
                 line_no
                 key)
          else if List.mem_assoc key seen
          then Error (Printf.sprintf ".env.local:%d: duplicate key %s" line_no key)
          else (
            match parse_value ~line:line_no raw_value with
            | Error _ as error -> error
            | Ok value -> loop (line_no + 1) ((key, value) :: seen) rest))
  in
  loop 1 [] lines
;;

let load ~root =
  let path = Filename.concat root ".env.local" in
  if not (Sys.file_exists path)
  then Ok []
  else (
    match In_channel.with_open_bin path In_channel.input_all with
    | contents -> parse contents
    | exception Sys_error _ -> Error "could not read .env.local")
;;
