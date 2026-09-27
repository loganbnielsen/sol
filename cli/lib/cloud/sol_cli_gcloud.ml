type reason =
  | Not_found
  | Other

(* The name that follows a literal marker, lowercased text assumed. Used to read
   the *subject* out of a gcloud message. *)
let names_after ~marker text =
  let marker_length = String.length marker in
  let text_length = String.length text in
  let is_name_char c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
  in
  let rec scan i acc =
    if i + marker_length > text_length
    then acc
    else if String.sub text i marker_length = marker
    then (
      let start = i + marker_length in
      let rec take j =
        if j < text_length && is_name_char text.[j] then take (j + 1) else j
      in
      let stop = take start in
      let name = String.sub text start (stop - start) in
      scan (max (i + 1) stop) (if name = "" then acc else name :: acc))
    else scan (i + 1) acc
  in
  List.rev (scan 0 [])
;;

(* The project(s) a gcloud message names. Both shapes are real: the resource path
   (`projects/<p>/locations/...`) and the quoted subject (`The project '<p>' was
   not found`). *)
let mentioned_projects stderr =
  let text = String.lowercase_ascii stderr in
  names_after ~marker:"projects/" text @ names_after ~marker:"project '" text
;;

(* The wording gcloud uses for "not there", across the commands Sol runs:
   `clusters describe` ("ResponseError: code=404, message=Not found"), the API's
   NOT_FOUND status, and compute's "The resource '...' was not found".

   Deliberately absent: "Could not fetch resource". It is gcloud's prefix for
   *every* API failure, so a 403 ("Could not fetch resource: - Required
   'compute.instances.get' permission") would read as absence -- which, for a
   cluster, means "a fresh target" (REFAC-136). The real 404 under that prefix
   carries "was not found" and is matched by it. *)
let not_found_wording =
  [ "code=404"; "httperror 404"; "not_found"; "not found"; "does not exist" ]
;;

let says_not_found ?project text =
  let lowered = String.lowercase_ascii text in
  let absent_wording =
    List.exists (fun needle -> Sol_cli_string.contains ~needle lowered) not_found_wording
  in
  let subject_matches =
    match project with
    | None -> true
    | Some project ->
      let project = String.lowercase_ascii project in
      List.for_all (fun mentioned -> mentioned = project) (mentioned_projects text)
  in
  absent_wording && subject_matches
;;

let classify ?project = function
  | Sol_cli_process.Non_zero { stderr; stdout; _ } ->
    if says_not_found ?project (stderr ^ "\n" ^ stdout) then Not_found else Other
  | Sol_cli_process.Spawn_failed _ | Sol_cli_process.Timeout _ -> Other
;;
