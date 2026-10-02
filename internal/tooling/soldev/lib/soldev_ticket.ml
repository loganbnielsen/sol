type ticket_state =
  | Backlog
  | Ready_for_engineering
  | Done

let state_to_dir = function
  | Backlog -> "BACKLOG"
  | Ready_for_engineering -> "READY_FOR_ENGINEERING"
  | Done -> "DONE"
;;

let state_of_dir = function
  | "BACKLOG" -> Some Backlog
  | "READY_FOR_ENGINEERING" -> Some Ready_for_engineering
  | "DONE" -> Some Done
  | _ -> None
;;

let all_states = [ Backlog; Ready_for_engineering; Done ]

let frontmatter_block content =
  match String.split_on_char '\n' content with
  | "---" :: rest ->
    let rec take acc = function
      | [] | "---" :: _ -> List.rev acc
      | line :: rest -> take (line :: acc) rest
    in
    Some (String.concat "\n" (take [] rest))
  | _ -> None
;;

let frontmatter content =
  let scalar_text = function
    | `Scalar { Yaml.value; _ } -> Some (String.trim value)
    | _ -> None
  in
  match frontmatter_block content with
  | None -> Ok []
  | Some block when String.trim block = "" -> Ok []
  | Some block ->
    (match Yaml.yaml_of_string block with
     | Error (`Msg message) -> Error ("frontmatter is not valid YAML: " ^ message)
     | Ok (`O { Yaml.m_members; _ }) ->
       m_members
       |> List.fold_left
            (fun acc (key, value) ->
               match acc, scalar_text key, value with
               | (Error _ as e), _, _ -> e
               | Ok fields, Some key, `Scalar { Yaml.value; style; _ } ->
                 let value = String.trim value in
                 let null = style = `Plain && List.mem value [ ""; "~"; "null" ] in
                 if null || value = "" then Ok fields else Ok ((key, value) :: fields)
               | Ok _, Some key, _ ->
                 Error (Printf.sprintf "frontmatter field %s must be a single value" key)
               | Ok _, None, _ -> Error "frontmatter keys must be plain names")
            (Ok [])
       |> Result.map List.rev
     | Ok _ -> Error "frontmatter must be a mapping of fields")
;;

let fields content = Result.value (frontmatter content) ~default:[]
let required_fields = [ "id"; "type"; "severity"; "source" ]

let wrapped_depends ~path content =
  let prefix = "**Depends on:**" in
  let is_field line = String.starts_with ~prefix (String.trim line) in
  let continues next =
    let next = String.trim next in
    next <> "" && next.[0] <> '*' && next.[0] <> '#'
  in
  let rec find = function
    | line :: rest when is_field line ->
      (match rest with
       | next :: _ when continues next ->
         Some
           (Printf.sprintf
              "%s: `**Depends on:**` wraps onto the next line, which is never parsed; \
               keep the field on one line and put commentary in its own paragraph"
              path)
       | _ -> None)
    | _ :: rest -> find rest
    | [] -> None
  in
  find (String.split_on_char '\n' content)
;;

let unreadable ~path content =
  match frontmatter_block content with
  | None ->
    Some
      (Printf.sprintf
         "%s: no frontmatter block; a ticket opens with `---` and names at least %s"
         path
         (String.concat ", " required_fields))
  | Some _ ->
    (match frontmatter content with
     | Error message -> Some (Printf.sprintf "%s: %s" path message)
     | Ok fields ->
       (match
          List.find_opt (fun field -> List.assoc_opt field fields = None) required_fields
        with
        | Some field ->
          Some
            (Printf.sprintf "%s: frontmatter field `%s` is missing or blank" path field)
        | None ->
          let id = List.assoc "id" fields in
          let filename_id = Filename.chop_suffix (Filename.basename path) ".md" in
          if id = filename_id
          then wrapped_depends ~path content
          else
            Some
              (Printf.sprintf
                 "%s: frontmatter id %s does not match filename id %s"
                 path
                 id
                 filename_id)))
;;

let fm_get fields key = List.assoc_opt key fields

let strip_trailing_period s =
  let s = String.trim s in
  let n = String.length s in
  if n > 0 && s.[n - 1] = '.' then String.sub s 0 (n - 1) else s
;;

let is_ticket_id_token_char c =
  (c >= 'A' && c <= 'Z')
  || (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || c = '_'
  || c = '-'
;;

let is_ticket_id_token s =
  match String.rindex_opt s '-' with
  | None -> false
  | Some i when i = 0 || i = String.length s - 1 -> false
  | Some i ->
    let prefix = String.sub s 0 i in
    let suffix = String.sub s (i + 1) (String.length s - i - 1) in
    let is_upper_or_underscore c = (c >= 'A' && c <= 'Z') || c = '_' in
    let is_digit c = c >= '0' && c <= '9' in
    prefix.[0] >= 'A'
    && prefix.[0] <= 'Z'
    && String.for_all is_upper_or_underscore prefix
    && String.length suffix > 0
    && String.for_all is_digit suffix
;;

let dedup_preserve_order tokens =
  let seen = Hashtbl.create (List.length tokens) in
  List.filter
    (fun token ->
       if Hashtbl.mem seen token
       then false
       else (
         Hashtbl.add seen token ();
         true))
    tokens
;;

let extract_ticket_ids raw =
  let n = String.length raw in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else if not (is_ticket_id_token_char raw.[i])
    then go (i + 1) acc
    else (
      let j = ref i in
      while !j < n && is_ticket_id_token_char raw.[!j] do
        incr j
      done;
      let token = String.sub raw i (!j - i) in
      let acc = if is_ticket_id_token token then token :: acc else acc in
      go !j acc)
  in
  go 0 [] |> dedup_preserve_order
;;

let starts_with_none raw =
  let raw = String.trim raw in
  let n = String.length raw in
  n >= 4
  && String.lowercase_ascii (String.sub raw 0 4) = "none"
  && (n = 4 || not (is_ticket_id_token_char raw.[4]))
;;

let parse_depends content =
  let prefix = "**Depends on:**" in
  let rec find = function
    | [] -> []
    | line :: rest ->
      let line = String.trim line in
      if String.starts_with ~prefix line
      then (
        let raw =
          String.sub
            line
            (String.length prefix)
            (String.length line - String.length prefix)
          |> strip_trailing_period
        in
        if starts_with_none raw then [] else extract_ticket_ids raw)
      else find rest
  in
  find (String.split_on_char '\n' content)
;;

let has_human_decision_gate content =
  List.exists
    (fun marker -> Soldev_string.contains_substring ~needle:marker content)
    [ "## Decision Required"
    ; "## Blocked On"
    ; "## Open Questions"
    ; "**Decision required:**"
    ; "**Blocked on:**"
    ; "**Open questions:**"
    ; "TBD"
    ; "TODO(decide)"
    ; "NEEDS HUMAN"
    ]
;;

let human_decision_details content =
  let lines = String.split_on_char '\n' content in
  let section_markers =
    [ "## Decision Required"
    ; "## Blocked On"
    ; "## Open Questions"
    ; "**Decision required:**"
    ; "**Blocked on:**"
    ; "**Open questions:**"
    ]
  in
  let marker_lines = [ "TBD"; "TODO(decide)"; "NEEDS HUMAN" ] in
  let is_bold_heading line =
    let line = String.trim line in
    String.starts_with ~prefix:"**" line
    && Soldev_string.contains_substring ~needle:":**" line
  in
  let is_boundary marker line =
    let line = String.trim line in
    if String.starts_with ~prefix:"## " marker
    then String.starts_with ~prefix:"## " line && line <> marker
    else is_bold_heading line && line <> marker
  in
  let rec collect_section marker acc = function
    | [] -> List.rev acc
    | line :: rest ->
      let trimmed = String.trim line in
      if acc = [] && trimmed <> marker
      then collect_section marker acc rest
      else if acc <> [] && is_boundary marker trimmed
      then List.rev acc
      else collect_section marker (line :: acc) rest
  in
  let sections =
    section_markers
    |> List.filter_map (fun marker ->
      let section = collect_section marker [] lines in
      if section = [] then None else Some (String.concat "\n" section))
  in
  let marker_hits =
    lines
    |> List.filter (fun line ->
      List.exists (fun m -> Soldev_string.contains_substring ~needle:m line) marker_lines)
  in
  String.concat "\n\n" (sections @ marker_hits)
;;

let is_bold_field_line line =
  let line = String.trim line in
  match String.index_opt line ':' with
  | None -> false
  | Some colon ->
    String.length line >= 4
    && String.sub line 0 2 = "**"
    && colon + 3 <= String.length line
    && String.sub line (colon + 1) 2 = "**"
;;

let is_heading line =
  let line = String.trim line in
  String.length line > 0 && line.[0] = '#'
;;

let strip_heading_markers line =
  let line = String.trim line in
  let n = String.length line in
  let rec first_content i =
    if i < n && line.[i] = '#' then first_content (i + 1) else i
  in
  let start = first_content 0 in
  String.trim (String.sub line start (n - start))
;;

type premise_verdict =
  | Premise_holds
  | Premise_stale
  | Premise_unverified of string

let premise_of content = fm_get (fields content) "premise"

let unquote token =
  let n = String.length token in
  if
    n >= 2
    && ((token.[0] = '\'' && token.[n - 1] = '\'')
        || (token.[0] = '"' && token.[n - 1] = '"'))
  then String.sub token 1 (n - 2)
  else token
;;

let probe_shell_metachars = "><|&;()$`*?[]{}~"
let existence_test_flags = [ "-e"; "-f"; "-d"; "-s"; "-h"; "-L" ]

let path_like token =
  let token = unquote token in
  let n = String.length token in
  n > 0
  && token.[0] <> '-'
  && token <> "."
  && token <> ".."
  && String.contains token '/'
  && (not (String.contains token ':'))
  && not (String.exists (fun c -> String.contains probe_shell_metachars c) token)
;;

let named_paths probe =
  let tokens = String.split_on_char ' ' probe in
  let rec go previous acc = function
    | [] -> List.rev acc
    | token :: rest ->
      let trimmed = String.trim token in
      let quoted =
        String.length trimmed >= 2
        && ((trimmed.[0] = '\'' && trimmed.[String.length trimmed - 1] = '\'')
            || (trimmed.[0] = '"' && trimmed.[String.length trimmed - 1] = '"'))
      in
      let follows_existence_test =
        Option.fold ~none:false ~some:(fun p -> List.mem p existence_test_flags) previous
      in
      let acc =
        if (not quoted) && (not follows_existence_test) && path_like token
        then token :: acc
        else acc
      in
      go (Some (unquote trimmed)) acc rest
  in
  go None [] tokens
;;

let missing_named_paths ~root probe =
  named_paths probe
  |> List.filter (fun named ->
    let path = if Filename.is_relative named then Filename.concat root named else named in
    not (Sys.file_exists path))
  |> List.sort_uniq String.compare
;;

let first_line text =
  match String.split_on_char '\n' text with
  | [] -> ""
  | line :: _ -> String.trim line
;;

let cap_description text =
  if String.length text <= 120 then text else String.sub text 0 120 ^ "..."
;;

let premise_verdict ~exit_code ~missing_paths ~output =
  match missing_paths with
  | _ :: _ ->
    Premise_unverified
      (Printf.sprintf
         "the probe names %s, which does not exist in the tree, so it cannot decide the \
          premise"
         (String.concat ", " missing_paths))
  | [] ->
    (match exit_code with
     | 0 -> Premise_stale
     | 1 -> Premise_holds
     | code ->
       let detail = first_line output in
       let detail = if detail = "" then "" else " — " ^ cap_description detail in
       Premise_unverified
         (Printf.sprintf
            "the probe exited %d (0 = premise stale, 1 = premise holds), which decides \
             nothing%s"
            code
            detail))
;;

let ticket_title content =
  match fm_get (fields content) "title" with
  | Some title -> title
  | None ->
    let lines = String.split_on_char '\n' content in
    let after_frontmatter = function
      | "---" :: rest ->
        let rec skip = function
          | [] -> []
          | "---" :: rest -> rest
          | _ :: rest -> skip rest
        in
        skip rest
      | lines -> lines
    in
    after_frontmatter lines
    |> List.find_opt (fun line ->
      let line = String.trim line in
      line <> "" && not (is_bold_field_line line))
    |> Option.map (fun line ->
      if is_heading line then strip_heading_markers line else String.trim line)
    |> Option.value ~default:"-"
;;

let find_ticket ticket_id =
  List.find_map
    (fun state ->
       let dir = state_to_dir state in
       let path = Printf.sprintf "internal/pipeline/tickets/%s/%s.md" dir ticket_id in
       if Sys.file_exists path then Some (state, path) else None)
    all_states
;;

let dependency_status dep =
  match find_ticket dep with
  | None -> `Unknown
  | Some (Done, _) -> `Done
  | Some (state, _) -> `Blocked state
;;

let dependency_summary deps =
  match deps with
  | [] -> "none"
  | deps -> String.concat ", " deps
;;

let find_dependency_cycle_from ~deps_of start =
  let cycle_from rev_path repeated =
    let rec drop = function
      | [] -> []
      | x :: rest -> if x = repeated then x :: rest else drop rest
    in
    drop (List.rev rev_path)
  in
  let rec walk path id =
    if List.mem id path
    then Some (cycle_from (id :: path) id)
    else List.find_map (walk (id :: path)) (deps_of id)
  in
  walk [] start
;;

let find_dependency_cycle ticket_id =
  find_dependency_cycle_from
    ~deps_of:(fun id ->
      match find_ticket id with
      | None -> []
      | Some (_, path) ->
        parse_depends (In_channel.with_open_text path In_channel.input_all))
    ticket_id
;;

let cycle_blocks cycle = List.for_all (fun id -> dependency_status id <> `Done) cycle

let readiness_label ~ticket_id state content =
  if has_human_decision_gate content
  then "needs-human"
  else (
    let deps = parse_depends content in
    match find_dependency_cycle ticket_id with
    | Some cycle when cycle_blocks cycle ->
      "blocked: dependency cycle " ^ String.concat " -> " cycle
    | _ ->
      (match List.find_opt (fun dep -> dependency_status dep <> `Done) deps with
       | Some dep ->
         (match dependency_status dep with
          | `Unknown -> "blocked: unknown " ^ dep
          | `Blocked s -> "blocked: " ^ dep ^ " in " ^ state_to_dir s
          | `Done -> "actionable")
       | None -> if state = Ready_for_engineering then "actionable" else "-"))
;;
