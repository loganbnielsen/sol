let squeeze line =
  String.to_seq line
  |> Seq.filter (fun c -> c <> ' ' && c <> '\t' && c <> '\r')
  |> String.of_seq
;;

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
  let classify_inline name line_no body =
    let squeezed = squeeze body in
    if Sol_cli_string.contains ~needle:sensitive_true squeezed
    then sensitive := name :: !sensitive
    else if Sol_cli_string.contains ~needle:sensitive_prefix squeezed
    then unreadable name line_no
  in
  lines
  |> List.iteri (fun index line ->
    let line_no = index + 1 in
    match !current with
    | Some name ->
      if String.equal (drop_trailing_cr line) "}"
      then current := None
      else classify name line_no line
    | None ->
      variable_header line
      |> Option.iter (fun (name, body) ->
        if String.contains body '}'
        then classify_inline name line_no body
        else current := Some name));
  match !failure with
  | Some message -> Error message
  | None -> Ok (List.sort_uniq String.compare !sensitive)
;;

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
          (tf
           |> List.map (fun name ->
             let path = Filename.concat root name in
             name, In_channel.with_open_bin path In_channel.input_all))
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
