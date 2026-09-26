(* FEAT-100: tests used to write one file per target
   (sol/<env>/<provider>/<region>.yml). [write ~target text] keeps that shape for
   the test author -- [text] is what such a file held, a [target:] block plus
   optional [resources:] and [services:] -- and records it as a target body in
   sol/environments.yml, regenerated from every target written so far in the
   current directory. Writing the same target again replaces it. *)

let written : (string, (string * string) list) Hashtbl.t = Hashtbl.create 8

let indent_of line =
  let n = String.length line in
  let rec go i = if i < n && line.[i] = ' ' then go (i + 1) else i in
  go 0
;;

(* The old file's [target:] children move up to the body's top level; its
   [resources:]/[services:] sections stay as they are. *)
let body_of_target_file text =
  let lines = String.split_on_char '\n' text in
  let in_target = ref false in
  List.filter_map
    (fun line ->
       let trimmed = String.trim line in
       let ind = indent_of line in
       if trimmed = "target:" && ind = 0
       then (
         in_target := true;
         None)
       else if trimmed = "" || (String.length trimmed > 0 && trimmed.[0] = '#')
       then Some line
       else if ind = 0
       then (
         in_target := false;
         Some line)
       else if !in_target && ind >= 2
       then Some (String.sub line 2 (String.length line - 2))
       else Some line)
    lines
;;

let mkdir_p path =
  let rec go p =
    if p <> "." && p <> "/" && not (Sys.file_exists p)
    then (
      go (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  go path
;;

let render entries =
  let envs =
    List.fold_left
      (fun acc (target, _) ->
         let env = List.hd (String.split_on_char '/' target) in
         if List.mem env acc then acc else acc @ [ env ])
      []
      entries
  in
  let buf = Buffer.create 512 in
  List.iter
    (fun env ->
       Buffer.add_string buf (env ^ ":\n  targets:\n");
       List.iter
         (fun (target, text) ->
            match String.split_on_char '/' target with
            | [ e; provider; region ] when e = env ->
              Buffer.add_string buf (Printf.sprintf "    %s/%s:\n" provider region);
              List.iter
                (fun line ->
                   if String.trim line <> ""
                   then Buffer.add_string buf ("      " ^ line ^ "\n"))
                (body_of_target_file text)
            | _ -> ())
         entries)
    envs;
  Buffer.contents buf
;;

let write ~target text =
  let dir = Sys.getcwd () in
  let entries = Option.value (Hashtbl.find_opt written dir) ~default:[] in
  let entries =
    if List.mem_assoc target entries
    then List.map (fun (t, x) -> if t = target then t, text else t, x) entries
    else entries @ [ target, text ]
  in
  Hashtbl.replace written dir entries;
  mkdir_p "sol";
  let oc = open_out "sol/environments.yml" in
  output_string oc (render entries);
  close_out oc
;;
