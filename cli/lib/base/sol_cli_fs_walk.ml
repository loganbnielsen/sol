type error =
  | Absent of string
  | Unreadable of string * string

let to_string = function
  | Absent path -> Printf.sprintf "%s: no such directory" path
  | Unreadable (path, reason) -> Printf.sprintf "%s: %s" path reason
;;

let entries path =
  if not (Sys.file_exists path)
  then Error (Absent path)
  else if not (Sys.is_directory path)
  then Error (Unreadable (path, "not a directory"))
  else (
    match Sys.readdir path with
    | names -> Ok (List.sort String.compare (Array.to_list names))
    | exception Sys_error reason -> Error (Unreadable (path, reason)))
;;

let selected path keep =
  entries path
  |> Result.map (fun names ->
    names
    |> List.filter (fun name ->
      let entry = Filename.concat path name in
      Sys.file_exists entry && keep (Sys.is_directory entry)))
;;

let dirs path = selected path (fun is_dir -> is_dir)
let files path = selected path not
