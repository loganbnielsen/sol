(* REFAC-128: copy one scaffold template tree into a destination.

   The walk is deliberately dumb: it reads a directory listing, sorts it, and
   writes (or merges) each file. Everything that decides *what* a generated
   project says lives in the template files under
   platform/shared/templates/<kind>/; everything that decides *where it goes and
   with which variables* lives in Sol_cli_cmd_new. *)

open Result.Syntax

type rule =
  | Write
  | Skip_if_exists
  | Patch_modules of string

let kinds = [ "workspace"; "svc"; "worker"; "fn"; "event" ]

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | content -> Ok content
  | exception Sys_error message ->
    Error (Printf.sprintf "could not read %s: %s" path message)
;;

let dir_of ~root ~kind = Filename.concat root kind

(* Every template of [kind], relative to its kind directory, sorted. A [Sys_error]
   is an [Error] naming the directory: a kind with no tree is a broken install,
   not an empty scaffold. *)
let plan ~root ~kind =
  let base = dir_of ~root ~kind in
  let rec walk rel acc =
    match Sys.readdir (Filename.concat base rel) with
    | exception Sys_error message ->
      Error (Printf.sprintf "no %s templates under %s: %s" kind root message)
    | entries ->
      Array.sort String.compare entries;
      let rec iter acc index =
        if index >= Array.length entries
        then Ok acc
        else (
          let entry = entries.(index) in
          let rel' = if rel = "" then entry else Filename.concat rel entry in
          if Sys.is_directory (Filename.concat base rel')
          then (
            match walk rel' acc with
            | Ok acc -> iter acc (index + 1)
            | Error _ as error -> error)
          else iter (rel' :: acc) (index + 1))
      in
      iter acc 0
  in
  match walk "" [] with
  | Error message -> Error message
  | Ok rels -> Ok (List.sort String.compare rels)
;;

let text ~root ~kind ~rel = read_file (Filename.concat (dir_of ~root ~kind) rel)

(* Append [new_mod] to the "(modules ...)" stanza in [path]. Handles the standard
   single-line form "(modules Foo Bar)". A file whose stanza cannot be found is
   reported and left alone, as it always was: the alternative is refusing an
   event because a hand-edited dune file does not look like the template. *)
let patch_modules_stanza path new_mod =
  let ic = open_in path in
  let content = In_channel.input_all ic in
  close_in ic;
  let prefix = "(modules " in
  let plen = String.length prefix in
  let clen = String.length content in
  let rec find_prefix i =
    if i > clen - plen
    then None
    else if String.sub content i plen = prefix
    then Some (i + plen)
    else find_prefix (i + 1)
  in
  match find_prefix 0 with
  | None ->
    Sol_cli_report.app
      "  note: could not locate (modules ...) in %s — add %s manually"
      path
      new_mod
  | Some pos ->
    let rec find_close i depth =
      if i >= clen
      then clen
      else (
        match content.[i] with
        | '(' -> find_close (i + 1) (depth + 1)
        | ')' -> if depth = 0 then i else find_close (i + 1) (depth - 1)
        | _ -> find_close (i + 1) depth)
    in
    let close = find_close pos 0 in
    let updated =
      String.sub content 0 close ^ " " ^ new_mod ^ String.sub content close (clen - close)
    in
    let oc = open_out path in
    output_string oc updated;
    close_out oc;
    Sol_cli_report.app "  updated  %s" path
;;

let copy ~root ~kind ~dest ~vars ~rule =
  let* rels = plan ~root ~kind in
  let rec iter written = function
    | [] -> Ok (List.rev written)
    | rel :: rest ->
      let v = vars rel in
      let target = Filename.concat dest (Sol_cli_scaffold.subst v rel) in
      (match rule rel with
       | Skip_if_exists when Sys.file_exists target -> iter written rest
       | Patch_modules module_ when Sys.file_exists target ->
         patch_modules_stanza target module_;
         iter (target :: written) rest
       | Write | Skip_if_exists | Patch_modules _ ->
         let* content = text ~root ~kind ~rel in
         Sol_cli_scaffold.write_file
           ~path:target
           ~content:(Sol_cli_scaffold.subst v content);
         iter (target :: written) rest)
  in
  iter [] rels
;;
