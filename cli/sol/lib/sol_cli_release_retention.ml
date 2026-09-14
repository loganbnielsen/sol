(* FEAT-072 / DEC-018: bounded release-history retention. See the .mli. *)

let default_keep = 20

let select ~keep ~current ~previous entries =
  (* Collapse duplicate deploys of one release to its newest appearance, so the
     window counts distinct releases rather than deploy events. *)
  let latest =
    List.fold_left
      (fun acc (release_id, created_at) ->
         match List.assoc_opt release_id acc with
         | Some existing when String.compare existing created_at >= 0 -> acc
         | _ -> (release_id, created_at) :: List.remove_assoc release_id acc)
      []
      entries
  in
  (* Newest first; tie-break on id so the result is a function of the input set
     and not of the order the cluster happened to return. *)
  let newest_first =
    List.sort
      (fun (id_a, at_a) (id_b, at_b) ->
         let by_time = String.compare at_b at_a in
         if by_time <> 0 then by_time else String.compare id_a id_b)
      latest
  in
  let protected release_id =
    String.equal release_id current
    ||
    match previous with
    | Some p -> String.equal release_id p
    | None -> false
  in
  let window = newest_first |> List.filteri (fun i _ -> i < max keep 0) |> List.map fst in
  newest_first
  |> List.filter (fun (release_id, _) ->
    (not (List.mem release_id window)) && not (protected release_id))
  |> List.map fst
  |> List.rev
;;

let prune ~ctx ~workspace ~keep ~current ~previous =
  match Sol_cli_release_store.list_with_creation ~ctx ~workspace with
  | Error msg -> Error msg
  | Ok records ->
    let entries =
      List.map
        (fun ((record : Sol_cli_release.t), created_at) -> record.release_id, created_at)
        records
    in
    let ids = select ~keep ~current ~previous entries in
    let rec delete acc = function
      | [] -> Ok (List.rev acc)
      | release_id :: rest ->
        (match Sol_cli_release_store.delete ~ctx ~release_id with
         | Ok () -> delete (release_id :: acc) rest
         | Error msg ->
           Error (Printf.sprintf "could not prune release %s: %s" release_id msg))
    in
    delete [] ids
;;
