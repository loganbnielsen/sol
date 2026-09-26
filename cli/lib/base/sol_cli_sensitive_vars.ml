(* SEC-010. Replaces the HARDEN-002 run-1 [Sol_cli_db_credential], which asked
   "does this provider create Postgres?" through a wildcard provider match
   ([Aws -> true | _ -> false]) and so never guarded GCP, whose root creates Cloud
   SQL from the same [db_password]. The two concerns it conflated now live where
   they belong: Terraform refuses a missing required secret (the AWS root's
   precondition on the database, the GCP root's required variable), and Sol
   refuses to put any secret the root declares into the argv it logs.

   AUDIT-POST-006: the reader below is deliberately small -- a whole HCL parser is
   not warranted for "which of this root's variables are secrets". It must not,
   however, assume one layout and then answer "no secrets" when the layout differs,
   because that answer is indistinguishable from a root that declares none. So it
   tolerates what a valid root may contain (a trailing comment, a single-line block,
   any whitespace) and, when it meets a [sensitive] assignment it cannot classify,
   it fails closed instead of skipping it.

   The layouts it must tolerate were checked against Terraform 1.9.8 rather than
   assumed: `variable "x" { sensitive = true }` on one line is valid and
   `terraform fmt` leaves it alone, and `sensitive = true # comment` is fmt-clean.
   A `{` on the line after the header is *invalid* HCL ("Invalid block definition"),
   so no root can contain one and this reader does not pretend to accept it. *)

(* Every space and tab removed, so `sensitive=true`, `sensitive = true` and a
   tab-indented form all compare equal. *)
let squeeze line =
  String.to_seq line
  |> Seq.filter (fun c -> c <> ' ' && c <> '\t' && c <> '\r')
  |> String.of_seq
;;

(* An HCL comment runs from an unquoted `#` or `//` to the end of the line. Quotes
   matter: an error_message string can contain either character, and cutting there
   would truncate the line the fixture uses to prove a brace inside a string does
   not end a block. *)
let strip_comment line =
  let n = String.length line in
  let rec scan i quoted =
    if i >= n
    then line
    else (
      match line.[i] with
      | '"' -> scan (i + 1) (not quoted)
      | '#' when not quoted -> String.sub line 0 i
      | '/' when (not quoted) && i + 1 < n && line.[i + 1] = '/' -> String.sub line 0 i
      | _ -> scan (i + 1) quoted)
  in
  scan 0 false
;;

let drop_trailing_cr line =
  let n = String.length line in
  if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line
;;

(* A top-level `variable "name" {` opens a block. HCL requires the `{` on the same
   line as the header, so a header without one is not a block and a root containing
   it does not parse. The part of the line after the header is the body when the
   block closes on the same line. *)
let variable_header line =
  let line = String.trim line in
  let prefix = "variable \"" in
  let plen = String.length prefix in
  if String.length line <= plen || not (String.equal (String.sub line 0 plen) prefix)
  then None
  else (
    match String.index_from_opt line plen '"' with
    | Some close when close > plen ->
      let name = String.sub line plen (close - plen) in
      let rest = String.sub line (close + 1) (String.length line - close - 1) in
      let rest = strip_comment rest in
      if String.contains rest '{' then Some (name, rest) else None
    | _ -> None)
;;

let sensitive_prefix = "sensitive="
let sensitive_true = "sensitive=true"
let sensitive_false = "sensitive=false"

(* Walk one file: which of its variables declare [sensitive = true], or an error
   naming the line whose [sensitive] declaration could not be read.

   A variable block ends at a `}` in the first column, which is what separates a
   top-level block from a nested one: a `validation { ... }` block is indented, and
   both providers write it that way. *)
let declared_in_one ~file contents =
  let lines = String.split_on_char '\n' contents in
  let sensitive = ref [] in
  let current = ref None in
  let failure = ref None in
  let prefix_length = String.length sensitive_prefix in
  let unreadable name line_no =
    if !failure = None
    then
      failure
      := Some
           (Printf.sprintf
              "%s:%d: the `sensitive` declaration of %s has a value the reader cannot \
               evaluate, so Sol cannot tell whether the variable is a secret. Declare \
               `sensitive = true` or `sensitive = false`."
              file
              line_no
              name)
  in
  (* A body line: the whole line is one argument, so it is either exactly a
     classified `sensitive` assignment or something else. *)
  let classify name line_no line =
    match squeeze (strip_comment line) with
    | squeezed when String.equal squeezed sensitive_true ->
      sensitive := name :: !sensitive
    | squeezed when String.equal squeezed sensitive_false -> ()
    | squeezed
      when String.length squeezed >= prefix_length
           && String.equal (String.sub squeezed 0 prefix_length) sensitive_prefix ->
      unreadable name line_no
    | _ -> ()
  in
  (* A one-line block body carries the assignment inside other text, so the value
     cannot be delimited the way a whole line can. Searching for the assignment is
     the conservative side: a body that mentions `sensitive` but not
     `sensitive = true` is reported rather than assumed harmless. *)
  let classify_inline name line_no body =
    let squeezed = squeeze body in
    if Sol_cli_string.contains ~needle:sensitive_true squeezed
    then sensitive := name :: !sensitive
    else if Sol_cli_string.contains ~needle:sensitive_prefix squeezed
    then unreadable name line_no
  in
  List.iteri
    (fun index line ->
       let line_no = index + 1 in
       match !current with
       | Some name ->
         if String.equal (drop_trailing_cr line) "}"
         then current := None
         else classify name line_no line
       | None ->
         (match variable_header line with
          | None -> ()
          | Some (name, body) ->
            if String.contains body '}'
            then classify_inline name line_no body
            else current := Some name))
    lines;
  match !failure with
  | Some message -> Error message
  | None -> Ok (List.sort_uniq String.compare !sensitive)
;;

(* Names from several files, without duplicates. *)
let declared_in files =
  let rec go acc = function
    | [] -> Ok (List.sort_uniq String.compare acc)
    | (file, contents) :: rest ->
      (match declared_in_one ~file contents with
       | Ok names -> go (List.rev_append names acc) rest
       | Error _ as error -> error)
  in
  go [] files
;;

let declared ~root =
  match Sys.readdir root with
  | exception Sys_error message ->
    Error (Printf.sprintf "cannot read the Terraform root %s: %s" root message)
  | entries ->
    let tf =
      Array.to_list entries
      |> List.filter (fun name -> Filename.check_suffix name ".tf")
      |> List.sort String.compare
    in
    let files =
      try
        Ok
          (List.map
             (fun name ->
                let path = Filename.concat root name in
                name, In_channel.with_open_bin path In_channel.input_all)
             tf)
      with
      | Sys_error message ->
        Error (Printf.sprintf "cannot read the Terraform root %s: %s" root message)
    in
    Result.bind files declared_in
;;

let key_of var =
  match String.index_opt var '=' with
  | Some i -> String.sub var 0 i
  | None -> var
;;

let refuse_on_command_line ~sensitive ~vars =
  match List.find_opt (fun var -> List.mem (key_of var) sensitive) vars with
  | None -> Ok ()
  | Some var ->
    let name = key_of var in
    Error
      (Printf.sprintf
         "refusing %s on the terraform command line: the root declares it sensitive, and \
          Sol records the terraform command line in its run log, so the value would be \
          written to a file. Supply it out of band instead, from your secret store:\n\
         \      TF_VAR_%s=\"$(your-secret-tool get ...)\" sol cloud ...\n\
         \  and remove it from --var and from the target's variables."
         name
         name)
;;
