(* SEC-010. Replaces the HARDEN-002 run-1 [Sol_cli_db_credential], which asked
   "does this provider create Postgres?" through a wildcard provider match
   ([Aws -> true | _ -> false]) and so never guarded GCP, whose root creates Cloud
   SQL from the same [db_password]. The two concerns it conflated now live where
   they belong: Terraform refuses a missing required secret (the AWS root's
   precondition on the database, the GCP root's required variable), and Sol
   refuses to put any secret the root declares into the argv it logs. *)

(* [variable "name" {] at column 0 (terraform fmt layout) opens a top-level block. *)
let variable_name line =
  let prefix = "variable \"" in
  let plen = String.length prefix in
  if String.length line > plen && String.equal (String.sub line 0 plen) prefix
  then (
    match String.index_from_opt line plen '"' with
    | Some close when String.ends_with ~suffix:"{" (String.trim line) && close > plen ->
      Some (String.sub line plen (close - plen))
    | _ -> None)
  else None
;;

(* An indented [sensitive = true] (any spacing) inside the block. *)
let is_sensitive_true line =
  String.length line > 0
  && (line.[0] = ' ' || line.[0] = '\t')
  && String.equal
       (String.concat "" (String.split_on_char ' ' (String.trim line))
        |> String.split_on_char '\t'
        |> String.concat "")
       "sensitive=true"
;;

let declared_in_one contents =
  let lines = String.split_on_char '\n' contents in
  let _, found =
    List.fold_left
      (fun (current, found) line ->
         match variable_name line with
         | Some name -> Some name, found
         | None ->
           (match current with
            | None -> None, found
            | Some _ when String.equal line "}" -> None, found
            | Some name when is_sensitive_true line -> current, name :: found
            | Some _ -> current, found))
      (None, [])
      lines
  in
  found
;;

let declared_in files =
  List.concat_map (fun (_, contents) -> declared_in_one contents) files
  |> List.sort_uniq String.compare
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
    (try
       Ok
         (declared_in
            (List.map
               (fun name ->
                  let path = Filename.concat root name in
                  name, In_channel.with_open_bin path In_channel.input_all)
               tf))
     with
     | Sys_error message ->
       Error (Printf.sprintf "cannot read the Terraform root %s: %s" root message))
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
