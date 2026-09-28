let command argv =
  let result = Sol_process.run_argv argv in
  if Sol_process.succeeded result
  then Ok (String.trim result.stdout)
  else Soldev_exit.error (String.concat " " argv ^ ": " ^ result.stderr)
;;

let run ~apply ~pr ~worktree =
  let open Result.Syntax in
  let* path =
    try Ok (Unix.realpath worktree) with
    | Unix.Unix_error (error, _, _) -> Soldev_exit.error (Unix.error_message error)
  in
  let git args = command ([ "git"; "-C"; path ] @ args) in
  let* current = command [ "git"; "rev-parse"; "--show-toplevel" ] in
  let* listing = command [ "git"; "worktree"; "list"; "--porcelain"; "-z" ] in
  let records = String.split_on_char '\000' listing in
  let canonical = List.hd records in
  let rec entry = function
    | [] -> None
    | line :: rest when line = "worktree " ^ path ->
      let rec fields acc = function
        | "" :: _ | [] -> List.rev acc
        | field :: rest -> fields (field :: acc) rest
      in
      Some (fields [] rest)
    | _ :: rest -> entry rest
  in
  let* fields =
    match entry records with
    | None -> Soldev_exit.error "worktree is not registered in this repository"
    | Some fields -> Ok fields
  in
  let* () =
    if canonical = "worktree " ^ path || path = Unix.realpath current
    then Soldev_exit.error "cannot clean the canonical or current worktree"
    else if List.exists (String.starts_with ~prefix:"locked") fields
    then Soldev_exit.error "worktree is locked; leave active worktrees locked"
    else Ok ()
  in
  let* branch = git [ "symbolic-ref"; "--short"; "HEAD" ] in
  let* () =
    if branch = "main" || branch = "master"
    then Soldev_exit.error "cannot clean a primary branch"
    else Ok ()
  in
  let* repository = command [ "git"; "remote"; "get-url"; "origin" ] in
  let* json =
    command
      [ "gh"
      ; "pr"
      ; "view"
      ; string_of_int pr
      ; "--repo"
      ; repository
      ; "--json"
      ; "state,headRefName,headRefOid,isCrossRepository,baseRefName"
      ]
  in
  let* expected =
    try
      let open Yojson.Basic.Util in
      let j = Yojson.Basic.from_string json in
      if j |> member "state" |> to_string <> "MERGED"
      then Soldev_exit.error "PR is not merged"
      else if j |> member "isCrossRepository" |> to_bool
      then Soldev_exit.error "fork PRs cannot authorize local cleanup"
      else if j |> member "baseRefName" |> to_string <> "main"
      then Soldev_exit.error "PR was not merged into main"
      else if j |> member "headRefName" |> to_string <> branch
      then Soldev_exit.error "worktree branch does not match the PR"
      else Ok (j |> member "headRefOid" |> to_string)
    with
    | Yojson.Json_error message | Yojson.Basic.Util.Type_error (message, _) ->
      Soldev_exit.error ("invalid GitHub response: " ^ message)
  in
  let verify () =
    let* head = git [ "rev-parse"; "HEAD" ] in
    let* current_branch = git [ "symbolic-ref"; "--short"; "HEAD" ] in
    let* status =
      git [ "status"; "--porcelain"; "--untracked-files=all"; "--ignored=matching" ]
    in
    if head <> expected || current_branch <> branch
    then Soldev_exit.error "branch changed since the merged PR head; preserving it"
    else if status <> ""
    then Soldev_exit.error "worktree contains local files or edits; preserving it"
    else Ok ()
  in
  let* () = verify () in
  Printf.printf
    "%s worktree %s and branch %s (merged PR #%d)\n%!"
    (if apply then "Removing" else "Would remove")
    path
    branch
    pr;
  if not apply
  then Ok ()
  else
    let* () = verify () in
    let* _ = command [ "git"; "worktree"; "remove"; path ] in
    let* _ = command [ "git"; "update-ref"; "-d"; "refs/heads/" ^ branch; expected ] in
    Ok ()
;;
