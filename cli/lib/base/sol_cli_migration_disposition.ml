type t =
  | Expand
  | Contract

let to_string = function
  | Expand -> "expand"
  | Contract -> "contract"
;;

let header_prefix = "-- sol:disposition"

(* The tag is a narrowly-scoped header directive, not a substring anywhere in
   the file: only the first non-blank line is ever consulted. *)
let first_nonblank_line content =
  content
  |> String.split_on_char '\n'
  |> List.find_opt (fun line -> not (Sol_cli_string.is_blank line))
;;

let of_header_line line =
  let line = String.trim line in
  let prefix_len = String.length header_prefix in
  if String.length line < prefix_len || String.sub line 0 prefix_len <> header_prefix
  then
    Error
      (Printf.sprintf
         "is missing a sol:disposition header (expected the first line to be %S or %S)"
         (header_prefix ^ " expand")
         (header_prefix ^ " contract"))
  else (
    match String.trim (String.sub line prefix_len (String.length line - prefix_len)) with
    | "expand" -> Ok Expand
    | "contract" -> Ok Contract
    | other ->
      Error
        (Printf.sprintf
           "has a malformed sol:disposition header %S (expected \"expand\" or \
            \"contract\")"
           other))
;;

let of_file_content content =
  match first_nonblank_line content with
  | None -> Error "is missing a sol:disposition header (file is empty)"
  | Some line -> of_header_line line
;;

let read_file ~path =
  match
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  with
  | exception Sys_error msg -> Error (Printf.sprintf "could not read %s: %s" path msg)
  | content -> of_file_content content
;;
