(* FEAT-104: recording a generated workload's declared language in sol.yml.

   The manifest is hand-maintained, so this patches its text rather than
   re-rendering it: comments, blank lines and entries Sol did not write survive
   byte-for-byte, and only the lines Sol adds are emitted (by Sol_cli_yaml, so a
   name needing quotes gets them). The full interface rationale is in the .mli.

   Two rules keep that safe. The patcher only rewrites a shape it recognises --
   a block mapping with plain keys -- and refuses anything else, naming the file.
   And the text it is about to write is parsed back before it is written: if the
   result would not say what it intended, nothing is written at all. *)

open Result.Syntax

let manifest_name = "sol.yml"
let manifest_path root = Filename.concat root manifest_name

(* ── the file as text ────────────────────────────────────────────────────── *)

(* Lines plus whether the file ended with a newline, so a file Sol only adds to
   keeps the exact ending it had. *)
type doc =
  { lines : string list
  ; trailing_newline : bool
  }

let doc_of text =
  let trailing_newline = String.length text > 0 && text.[String.length text - 1] = '\n' in
  let lines = String.split_on_char '\n' text in
  let lines =
    if trailing_newline
    then (
      match List.rev lines with
      | "" :: rest -> List.rev rest
      | _ -> lines)
    else lines
  in
  { lines; trailing_newline }
;;

let text_of doc = String.concat "\n" doc.lines ^ if doc.trailing_newline then "\n" else ""

let leading_spaces line =
  let rec count i =
    if i < String.length line && line.[i] = ' ' then count (i + 1) else i
  in
  count 0
;;

let is_blank line = String.trim line = ""

(* A key at this indentation, whatever follows it: [services:], [services: {}],
   [charge_svc: {type: http}]. Used to *find* things. *)
let key_prefix ~indent key line =
  let length = String.length line in
  leading_spaces line = indent
  && length > indent
  && String.length key + 1 <= length - indent
  && String.equal (String.sub line indent (String.length key + 1)) (key ^ ":")
;;

(* A key alone on its line: [charge_svc:], with everything about it indented
   below. Only this shape can be inserted into -- [charge_svc: {}] has nowhere to
   put a child without rewriting the line the operator wrote. *)
let block_key ~indent key line =
  key_prefix ~indent key line && String.equal (String.trim line) (key ^ ":")
;;

let split_at list n =
  let rec go i acc = function
    | rest when i = n -> List.rev acc, rest
    | [] -> List.rev acc, []
    | x :: rest -> go (i + 1) (x :: acc) rest
  in
  go 0 [] list
;;

(* ── the lines Sol adds ──────────────────────────────────────────────────── *)

let indent_by n body =
  let pad = String.make n ' ' in
  let lines = String.split_on_char '\n' body in
  let lines =
    match List.rev lines with
    | "" :: rest -> List.rev rest
    | _ -> lines
  in
  (lines
   |> List.map (fun line -> if is_blank line then line else pad ^ line)
   |> String.concat "\n")
  ^ "\n"
;;

(* `  <name>:\n    language: <language>\n` -- one entry, indented under a
   top-level `services:`. *)
let entry_fragment ~name ~language =
  Sol_cli_yaml.(to_string (map [ name, map [ "language", string language ] ]))
  |> indent_by 2
;;

(* `    language: <language>\n` -- for an entry that already exists. *)
let language_fragment ~language =
  Sol_cli_yaml.(to_string (map [ "language", string language ])) |> indent_by 4
;;

let insert_after ~doc ~after ~fragment =
  let added =
    match List.rev (String.split_on_char '\n' fragment) with
    | "" :: rest -> List.rev rest
    | _ -> String.split_on_char '\n' fragment
  in
  let before, rest = split_at doc.lines (after + 1) in
  { doc with lines = before @ added @ rest }
;;

(* ── the patch ───────────────────────────────────────────────────────────── *)

type outcome =
  | Declared
  | Language_added
  | Already_declared

(* Where the entry for [name] goes, given the text as it stands. Returns the new
   text and what was done to it -- or a refusal, for a shape this cannot patch
   without rewriting lines the operator wrote. *)
let patch ~doc ~name ~language =
  let lines = Array.of_list doc.lines in
  let count = Array.length lines in
  let rec find_first from predicate =
    if from >= count
    then None
    else if predicate lines.(from)
    then Some from
    else find_first (from + 1) predicate
  in
  (* Where the block opened at [from] ends: the next non-blank line at a column
     <= [column] is a sibling or the next section. *)
  let block_end ~from ~column =
    let rec go i =
      if i >= count
      then count
      else (
        let line = lines.(i) in
        if (not (is_blank line)) && leading_spaces line <= column then i else go (i + 1))
    in
    go from
  in
  let unpatchable () =
    Error
      (Printf.sprintf
         "%s is not a shape Sol can record a declaration in without rewriting what you \
          wrote -- add `language: %s` under services.%s by hand"
         manifest_name
         language
         name)
  in
  match find_first 0 (key_prefix ~indent:0 "services") with
  | None ->
    (* No section at all: add one, keeping the file's own ending. *)
    let text = text_of doc in
    let text = if doc.trailing_newline then text else text ^ "\n" in
    Ok (text ^ "\nservices:\n" ^ entry_fragment ~name ~language, Declared)
  | Some services when not (block_key ~indent:0 "services" lines.(services)) ->
    unpatchable ()
  | Some services ->
    let services_end = block_end ~from:(services + 1) ~column:0 in
    let entry = find_first (services + 1) (fun line -> key_prefix ~indent:2 name line) in
    (match entry with
     | Some entry
       when entry < services_end && not (block_key ~indent:2 name lines.(entry)) ->
       unpatchable ()
     | Some entry when entry < services_end ->
       let entry_end = block_end ~from:(entry + 1) ~column:2 in
       let declares_language =
         match
           find_first (entry + 1) (fun line -> key_prefix ~indent:4 "language" line)
         with
         | Some line -> line < entry_end
         | None -> false
       in
       if declares_language
       then Ok (text_of doc, Already_declared)
       else
         Ok
           ( insert_after ~doc ~after:entry ~fragment:(language_fragment ~language)
             |> text_of
           , Language_added )
     | _ ->
       Ok
         ( insert_after ~doc ~after:services ~fragment:(entry_fragment ~name ~language)
           |> text_of
         , Declared ))
;;

(* ── reading and writing the file ────────────────────────────────────────── *)

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all) with
  | Sys_error msg -> Error msg
;;

(* REFAC-134: Sol_cli_fs's atomic write, keeping the mode the operator chose for
   sol.yml rather than the umask default. *)
let write_atomic path text =
  let perm =
    match Unix.stat path with
    | { Unix.st_perm; _ } -> Some st_perm
    | exception Unix.Unix_error _ -> None
  in
  Sol_cli_fs.write_atomic ?perm path text
;;

(* ── the interface ───────────────────────────────────────────────────────── *)

type plan =
  { path : string
  ; text : string option (* None when the manifest already says exactly this *)
  ; outcome : outcome
  }

let outcome plan = plan.outcome

(* What the text says about [name], or a refusal. This is the proof-read that
   makes the patcher safe: it can only ever be wrong in the direction of "write
   nothing". *)
let verify ~path ~text ~name ~language =
  let* services =
    Sol_cli_config.sol_yml_services_of_string ~path text
    |> Result.map_error Sol_cli_config.error_to_string
  in
  match
    List.find_opt (fun (s : Sol_cli_config.service) -> String.equal s.name name) services
  with
  | None -> Error (Printf.sprintf "%s: %s would not be declared after the edit" path name)
  | Some svc ->
    (match svc.language with
     | Some declared when declared = language -> Ok ()
     | declared ->
       Error
         (Printf.sprintf
            "%s: %s would declare language: %s, not %s"
            path
            name
            (match declared with
             | Some l -> Sol_cli_compat.to_string l
             | None -> "nothing")
            (Sol_cli_compat.to_string language)))
;;

let plan ~root ~name ~dir ~language =
  let path = manifest_path root in
  let* text = read_file path in
  let* services =
    Sol_cli_config.sol_yml_services ~root
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let lang = Sol_cli_compat.to_string language in
  let existing =
    List.find_opt (fun (s : Sol_cli_config.service) -> String.equal s.name name) services
  in
  let* () =
    match existing with
    | Some { Sol_cli_config.path = Some declared_at; _ }
      when not (String.equal declared_at dir) ->
      Error
        (Printf.sprintf
           "%s already declares %s at %s, and the manifest keys services by name, so \
            recording it for %s would mis-declare the other workload -- rename one of \
            them"
           manifest_name
           name
           declared_at
           dir)
    | Some { Sol_cli_config.language = Some declared_as; _ }
      when not (declared_as = language) ->
      Error
        (Printf.sprintf
           "%s already declares %s as language: %s, but this generator writes %s -- \
            resolve the declaration by hand"
           manifest_name
           name
           (Sol_cli_compat.to_string declared_as)
           lang)
    | _ -> Ok ()
  in
  match existing with
  | Some { Sol_cli_config.language = Some _; _ } ->
    (* The declaration is already there. Rewriting the file would change a file
       for nothing -- not even its modification time. *)
    Ok { path; text = None; outcome = Already_declared }
  | _ ->
    let* text, outcome = patch ~doc:(doc_of text) ~name ~language:lang in
    let* () = verify ~path ~text ~name ~language in
    Ok { path; text = Some text; outcome }
;;

let commit plan =
  match plan.text with
  | None -> Ok plan.outcome
  | Some text ->
    (match write_atomic plan.path text with
     | Ok () -> Ok plan.outcome
     | Error msg -> Error (Printf.sprintf "%s: %s" plan.path msg))
;;
