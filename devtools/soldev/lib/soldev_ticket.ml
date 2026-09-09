(* Only three persisted states remain (see REFAC-077) — see the .mli for the
   full rationale. *)
type ticket_state =
  | Backlog
  | Ready_for_engineering
  | Done

let state_to_dir = function
  | Backlog               -> "BACKLOG"
  | Ready_for_engineering -> "READY_FOR_ENGINEERING"
  | Done                  -> "DONE"

let state_of_dir = function
  | "BACKLOG"               -> Some Backlog
  | "READY_FOR_ENGINEERING" -> Some Ready_for_engineering
  | "DONE"                  -> Some Done
  | _                       -> None

let all_states = [
  Backlog;
  Ready_for_engineering;
  Done;
]

let parse_frontmatter content =
  match String.split_on_char '\n' content with
  | "---" :: rest ->
    let rec collect acc = function
      | [] | "---" :: _ -> acc
      | line :: rest ->
        (match String.index_opt line ':' with
         | Some i ->
           let key   = String.trim (String.sub line 0 i) in
           let value = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
           collect ((key, value) :: acc) rest
         | None -> collect acc rest)
    in
    collect [] rest
  | _ -> []

let fm_get fields key =
  match List.assoc_opt key fields with
  | Some v when v <> "" -> Some v
  | _ -> None

let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

(* Add or overwrite a `key: value` line inside the frontmatter block, leaving
   the rest of the ticket body untouched. Appends the field if not already
   present. Returns [content] unchanged if it has no frontmatter block. *)
let set_frontmatter_field content key value =
  match String.split_on_char '\n' content with
  | "---" :: rest ->
    let rec split_fm acc = function
      | "---" :: after -> Some (List.rev acc, after)
      | line :: after -> split_fm (line :: acc) after
      | [] -> None
    in
    (match split_fm [] rest with
     | None -> content
     | Some (fm_lines, body) ->
       let prefix = key ^ ":" in
       let is_field l = starts_with ~prefix l in
       let new_line = Printf.sprintf "%s: %s" key value in
       let fm_lines =
         if List.exists is_field fm_lines then
           List.map (fun l -> if is_field l then new_line else l) fm_lines
         else fm_lines @ [ new_line ]
       in
       String.concat "\n" (("---" :: fm_lines) @ ("---" :: body)))
  | _ -> content

let contains_substring ~needle s =
  let ln = String.length needle in
  let ls = String.length s in
  if ln = 0 then true
  else if ln > ls then false
  else
    let rec go i =
      if i > ls - ln then false
      else if String.sub s i ln = needle then true
      else go (i + 1)
    in
    go 0

let strip_trailing_period s =
  let s = String.trim s in
  let n = String.length s in
  if n > 0 && s.[n - 1] = '.' then String.sub s 0 (n - 1) else s

let is_ticket_id_token_char c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9') || c = '_' || c = '-'

(* A ticket ID looks like PREFIX-NUMBER, where PREFIX is uppercase
   letters/underscores (FEAT, AUDIT, CODEX_STYLE_AUDIT, ...) and NUMBER is
   digits (FEAT-033, CODEX_STYLE_AUDIT-006). Reject anything else so prose
   words in an annotated "Depends on:" line (e.g. "(done — merged as the
   evidence base for this ticket)", "conceptually", "in practice") never get
   mistaken for a dependency. *)
let is_ticket_id_token s =
  match String.rindex_opt s '-' with
  | None -> false
  | Some i when i = 0 || i = String.length s - 1 -> false
  | Some i ->
    let prefix = String.sub s 0 i in
    let suffix = String.sub s (i + 1) (String.length s - i - 1) in
    let is_upper_or_underscore c = (c >= 'A' && c <= 'Z') || c = '_' in
    let is_digit c = c >= '0' && c <= '9' in
    prefix.[0] >= 'A' && prefix.[0] <= 'Z'
    && String.for_all is_upper_or_underscore prefix
    && String.length suffix > 0
    && String.for_all is_digit suffix

(* Extract every ticket-ID-shaped token from a raw "Depends on:" value,
   ignoring parenthetical annotations, prose ("and", "in practice", "not a
   hard dependency"), and punctuation — a "Depends on:" line in this repo is
   free-form prose, not a structured list (e.g.
   "FEAT-034 (done), FEAT-035 (done)." or
   "FEAT-034 in practice — ... Not a hard code dependency."). *)
let dedup_preserve_order tokens =
  let seen = Hashtbl.create (List.length tokens) in
  List.filter
    (fun token ->
      if Hashtbl.mem seen token then false
      else (
        Hashtbl.add seen token ();
        true))
    tokens

let extract_ticket_ids raw =
  let n = String.length raw in
  let rec go i acc =
    if i >= n then List.rev acc
    else if not (is_ticket_id_token_char raw.[i]) then go (i + 1) acc
    else
      let j = ref i in
      while !j < n && is_ticket_id_token_char raw.[!j] do
        incr j
      done;
      let token = String.sub raw i (!j - i) in
      let acc = if is_ticket_id_token token then token :: acc else acc in
      go !j acc
  in
  go 0 [] |> dedup_preserve_order

(* "None." always means zero dependencies in this repo's convention, even
   when followed by an unrelated parenthetical aside that happens to mention
   another ticket (e.g. "None. (BUG-008's fix already unblocked this.)") —
   that mention is context, not a second dependency. *)
let starts_with_none raw =
  let raw = String.trim raw in
  let n = String.length raw in
  n >= 4
  && String.lowercase_ascii (String.sub raw 0 4) = "none"
  && (n = 4 || not (is_ticket_id_token_char raw.[4]))

let parse_depends content =
  let prefix = "**Depends on:**" in
  let rec find = function
    | [] -> []
    | line :: rest ->
      let line = String.trim line in
      if starts_with ~prefix line then
        let raw =
          String.sub line (String.length prefix)
            (String.length line - String.length prefix)
          |> strip_trailing_period
        in
        if starts_with_none raw then [] else extract_ticket_ids raw
      else find rest
  in
  find (String.split_on_char '\n' content)

let has_human_decision_gate content =
  List.exists (fun marker -> contains_substring ~needle:marker content) [
    "## Decision Required";
    "## Blocked On";
    "## Open Questions";
    "**Decision required:**";
    "**Blocked on:**";
    "**Open questions:**";
    "TBD";
    "TODO(decide)";
    "NEEDS HUMAN";
  ]

let human_decision_details content =
  let lines = String.split_on_char '\n' content in
  let section_markers = [
    "## Decision Required"; "## Blocked On"; "## Open Questions";
    "**Decision required:**"; "**Blocked on:**"; "**Open questions:**";
  ] in
  let marker_lines = [ "TBD"; "TODO(decide)"; "NEEDS HUMAN" ] in
  let is_bold_heading line =
    let line = String.trim line in
    starts_with ~prefix:"**" line && contains_substring ~needle:":**" line
  in
  let is_boundary marker line =
    let line = String.trim line in
    if starts_with ~prefix:"## " marker then
      starts_with ~prefix:"## " line && line <> marker
    else
      is_bold_heading line && line <> marker
  in
  let rec collect_section marker acc = function
    | [] -> List.rev acc
    | line :: rest ->
      let trimmed = String.trim line in
      if acc = [] && trimmed <> marker then collect_section marker acc rest
      else if acc <> [] && is_boundary marker trimmed then List.rev acc
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
      List.exists (fun m -> contains_substring ~needle:m line) marker_lines)
  in
  String.concat "\n\n" (sections @ marker_hits)

let ticket_title content =
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
       line <> "" && not (starts_with ~prefix:"**Depends on:**" line))
  |> Option.map String.trim
  |> Option.value ~default:"-"

let find_ticket ticket_id =
  List.find_map (fun state ->
    let dir  = state_to_dir state in
    let path = Printf.sprintf "pipeline/tickets/%s/%s.md" dir ticket_id in
    if Sys.file_exists path then Some (state, path) else None
  ) all_states

let dependency_status dep =
  match find_ticket dep with
  | None -> `Unknown
  | Some (Done, _) -> `Done
  | Some (state, _) -> `Blocked state

let dependency_summary deps =
  match deps with
  | [] -> "none"
  | deps -> String.concat ", " deps

let readiness_label state content =
  if has_human_decision_gate content then "needs-human"
  else
    let deps = parse_depends content in
    match List.find_opt (fun dep -> dependency_status dep <> `Done) deps with
    | Some dep ->
      (match dependency_status dep with
       | `Unknown -> "blocked: unknown " ^ dep
       | `Blocked s -> "blocked: " ^ dep ^ " in " ^ state_to_dir s
       | `Done -> "actionable")
    | None ->
      if state = Ready_for_engineering then "actionable" else "-"
