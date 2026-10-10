let indent_of line =
  let n = String.length line in
  let rec go i = if i < n && line.[i] = ' ' then go (i + 1) else i in
  go 0
;;

let body_of_target_file text =
  let lines = String.split_on_char '\n' text in
  let in_target = ref false in
  lines
  |> List.filter_map (fun line ->
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
  let rec app_units dir =
    if not (Sys.file_exists dir && Sys.is_directory dir)
    then []
    else
      Sys.readdir dir
      |> Array.to_list
      |> List.filter_map (fun child ->
        let path = Filename.concat dir child in
        if child.[0] = '.' || not (Sys.is_directory path)
        then None
        else if Filename.dirname dir = "app"
        then (
          match Sol_cli_manifest.primitive_of_suffix child with
          | None -> None
          | Some _ -> Some (Filename.basename dir, child, path))
        else None)
      |> fun immediate ->
      if immediate <> []
      then immediate
      else
        Sys.readdir dir
        |> Array.to_list
        |> List.filter_map (fun child ->
          let path = Filename.concat dir child in
          if child.[0] = '.' || not (Sys.is_directory path) then None else Some path)
        |> List.concat_map app_units
  in
  let synthesized_secret_lines text =
    if
      String.split_on_char '\n' text
      |> List.exists (fun line -> String.trim line = "secrets:")
    then []
    else
      app_units "app"
      |> List.concat_map (fun (domain, unit_name, dir) ->
        let user_keys =
          match Sol_cli_toml.load_result (Filename.concat dir "sol.toml") with
          | Ok config -> config.secret_keys
          | Error _ -> []
        in
        let keys =
          Sol_cli_manifest.required_secret_keys
            ~transport:Sol_cli_manifest.Sasl_ssl
            user_keys
        in
        [ "secrets:"; Printf.sprintf "  %s/%s:" domain unit_name ]
        @ List.map (fun key -> "    " ^ key ^ ": sol") keys)
  in
  envs
  |> List.iter (fun env ->
    Buffer.add_string buf (env ^ ":\n  targets:\n");
    entries
    |> List.iter (fun (target, text) ->
      match String.split_on_char '/' target with
      | [ e; provider; region ] when e = env ->
        Buffer.add_string buf (Printf.sprintf "    %s/%s:\n" provider region);
        let generated = synthesized_secret_lines text in
        List.iter
          (fun line ->
             if String.trim line <> "" then Buffer.add_string buf ("      " ^ line ^ "\n"))
          (body_of_target_file text @ generated)
      | _ -> ()));
  Buffer.contents buf
;;

let staging = "sol/.targets"

let rec staged_files dir =
  if not (Sys.file_exists dir)
  then []
  else if not (Sys.is_directory dir)
  then [ dir ]
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.concat_map (fun name -> staged_files (Filename.concat dir name))
;;

let target_of_staged path =
  let prefix = staging ^ "/" in
  let length = String.length prefix in
  String.sub path length (String.length path - length)
;;

let write ~target text =
  let path = Filename.concat staging target in
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc text;
  close_out oc;
  let entries =
    staged_files staging
    |> List.map (fun path ->
      target_of_staged path, In_channel.with_open_text path In_channel.input_all)
  in
  mkdir_p "sol";
  let oc = open_out "sol/environments.yml" in
  output_string oc (render entries);
  close_out oc
;;
