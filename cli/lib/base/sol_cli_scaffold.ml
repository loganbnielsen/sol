let replace_all ~pat ~with_ s =
  let pl = String.length pat in
  let sl = String.length s in
  let buf = Buffer.create (sl + 64) in
  let i = ref 0 in
  while !i < sl do
    if !i + pl <= sl && String.sub s !i pl = pat
    then (
      Buffer.add_string buf with_;
      i := !i + pl)
    else (
      Buffer.add_char buf s.[!i];
      incr i)
  done;
  Buffer.contents buf
;;

let subst vars s =
  List.fold_left
    (fun acc (k, v) -> replace_all ~pat:("{{" ^ k ^ "}}") ~with_:v acc)
    s
    vars
;;

(* REFAC-134: directory creation and writing are Sol_cli_fs's; a failure is
   returned, not raised. *)
let write_file ~path ~content =
  let open Result.Syntax in
  let* () = Sol_cli_fs.mkdir_p (Filename.dirname path) in
  let* () = Sol_cli_fs.write_atomic path content in
  Sol_cli_report.app "  created  %s" path;
  Ok ()
;;

let normalize s =
  String.map
    (function
      | '-' -> '_'
      | c -> c)
    (String.lowercase_ascii s)
;;

let capitalize_name s =
  let s = normalize s in
  if String.length s = 0
  then s
  else (
    let b = Bytes.of_string s in
    Bytes.set b 0 (Char.uppercase_ascii (Bytes.get b 0));
    Bytes.to_string b)
;;
