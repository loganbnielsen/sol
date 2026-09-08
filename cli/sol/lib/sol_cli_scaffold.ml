let replace_all ~pat ~with_ s =
  let pl = String.length pat in
  let sl = String.length s in
  let buf = Buffer.create (sl + 64) in
  let i = ref 0 in
  while !i < sl do
    if !i + pl <= sl && String.sub s !i pl = pat then begin
      Buffer.add_string buf with_;
      i := !i + pl
    end else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Buffer.contents buf

let subst vars s =
  List.fold_left (fun acc (k, v) ->
    replace_all ~pat:("{{" ^ k ^ "}}") ~with_:v acc
  ) s vars

(* Sys.file_exists follows symlinks and reports false for a broken one, so
   a dangling symlink at [dir] would fall through to Unix.mkdir, which then
   fails with EEXIST (the dirent itself exists) — silently "succeeding"
   with a dirent that's still unusable as a directory. Unix.stat also
   follows symlinks, so it correctly reports a working symlink-to-directory
   as usable; only a bare lstat (which doesn't follow) can tell "nothing
   here at all" apart from "a dirent here that stat couldn't resolve." *)
let usable_as_directory dir =
  match Unix.stat dir with
  | { Unix.st_kind = Unix.S_DIR; _ } -> true
  | _ | exception Unix.Unix_error _ -> false

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if usable_as_directory dir then ()
  else
    match Unix.lstat dir with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      mkdir_p (Filename.dirname dir);
      (try Unix.mkdir dir 0o755 with
       | Unix.Unix_error (Unix.EEXIST, _, _) ->
         (* Lost a race with a concurrent creator, or a broken symlink sits
            here — Unix.mkdir can't create over either. Re-check rather
            than treating EEXIST alone as success. *)
         if not (usable_as_directory dir) then
           raise (Failure (Printf.sprintf
             "could not create directory %s: path exists but is not usable as a directory (broken symlink?)" dir))
       | Unix.Unix_error (e, _, _) ->
         raise (Failure (Printf.sprintf "could not create directory %s: %s" dir (Unix.error_message e))))
    | exception Unix.Unix_error (e, _, _) ->
      raise (Failure (Printf.sprintf "could not create directory %s: %s" dir (Unix.error_message e)))
    | _ ->
      raise (Failure (Printf.sprintf
        "could not create directory %s: a non-directory already exists at that path" dir))

let write_file ~path ~content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Printf.printf "  created  %s\n%!" path

let link_dir ~path ~target =
  mkdir_p (Filename.dirname path);
  (try Unix.symlink target path
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Printf.printf "  linked   %s -> %s\n%!" path target

let normalize s =
  String.map (function '-' -> '_' | c -> c) (String.lowercase_ascii s)

let capitalize_name s =
  let s = normalize s in
  if String.length s = 0 then s
  else begin
    let b = Bytes.of_string s in
    Bytes.set b 0 (Char.uppercase_ascii (Bytes.get b 0));
    Bytes.to_string b
  end
