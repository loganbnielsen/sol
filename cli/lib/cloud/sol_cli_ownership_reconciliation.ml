open Sol_cli_resource_identity

type candidate =
  { address : string
  ; resource_class : string
  ; found : string
  ; import_identity : string
  }

type disposition =
  | Recover of candidate
  | Already_owned of
      { address : string
      ; found : string
      }
  | By_contract of
      { resource_class : string
      ; found : string
      }
  | Cannot_recover of
      { resource_class : string
      ; found : string
      ; reason : string
      }
  | Unmapped of
      { resource_class : string
      ; found : string
      }

let matches (entry : entry) ~resource_class ~found =
  entry.resource_class = resource_class
  && entry.observed_as <> ""
  && Sol_cli_string.contains ~needle:entry.observed_as found
;;

let disposition_of ~entries ~state_addresses ~resource_class found =
  match
    List.filter (fun (entry : entry) -> matches entry ~resource_class ~found) entries
  with
  | [ entry ] ->
    if not (Sol_cli_resource_identity.recoverable entry)
    then (
      match entry.ownership with
      | Sol_cli_resource_identity.External_by_contract _ ->
        By_contract { resource_class; found }
      | ownership ->
        Cannot_recover
          { resource_class
          ; found
          ; reason = Sol_cli_resource_identity.ownership_reason ownership
          })
    else if List.mem entry.address state_addresses
    then Already_owned { address = entry.address; found }
    else
      Recover
        { address = entry.address
        ; resource_class
        ; found
        ; import_identity = entry.import_identity
        }
  | [] -> Unmapped { resource_class; found }
  | candidates ->
    Cannot_recover
      { resource_class
      ; found
      ; reason =
          Printf.sprintf
            "%d registry entries describe this class and name (%s), so the mapping to a \
             Terraform address is ambiguous and recovery refuses to guess"
            (List.length candidates)
            (String.concat
               ", "
               (List.map (fun (entry : entry) -> entry.address) candidates))
      }
;;

let dispositions ~entries ~state_addresses observations =
  observations
  |> List.concat_map (function
    | Sol_cli_absence.Present { resource_class; found; _ } ->
      List.map (disposition_of ~entries ~state_addresses ~resource_class) found
    | Sol_cli_absence.Absent _
    | Sol_cli_absence.External _
    | Sol_cli_absence.Not_attributable _
    | Sol_cli_absence.Unobservable _ -> [])
;;

let candidate = function
  | Recover candidate -> Some candidate
  | Already_owned _ | By_contract _ | Cannot_recover _ | Unmapped _ -> None
;;

let outcome ?(dry_run = false) dispositions =
  let restored = List.filter_map candidate dispositions in
  let refused =
    List.filter
      (function
        | Cannot_recover _ | Unmapped _ -> true
        | Recover _ | Already_owned _ | By_contract _ -> false)
      dispositions
  in
  let buffer = Buffer.create 256 in
  let line format = Printf.ksprintf (Buffer.add_string buffer) format in
  if restored <> []
  then (
    List.iter
      (fun restored ->
         line "Found %s %s.\n" restored.resource_class restored.found;
         line
           (if dry_run
            then "Would restore Terraform ownership:\n  %s\n"
            else "Restored Terraform ownership:\n  %s\n")
           restored.address)
      restored;
    if dry_run
    then line "Infrastructure ownership is reconcilable; nothing was changed.\n"
    else line "Infrastructure ownership is reconciled.\n")
  else if refused = []
  then line "Infrastructure ownership is reconciled.\nNo changes.\n"
  else (
    line "Infrastructure ownership is not reconciled:\n";
    List.iter
      (function
        | Cannot_recover { resource_class; found; reason } ->
          line "  %s %s cannot be reconciled: %s\n" resource_class found reason
        | Unmapped { resource_class; found } ->
          line
            "  %s %s has no Terraform address Sol can attribute it to, so it is left alone\n"
            resource_class
            found
        | Recover _ | Already_owned _ | By_contract _ -> ())
      refused);
  Buffer.contents buffer
;;

let unreconciled dispositions =
  dispositions
  |> List.filter (function
    | Recover _ | Cannot_recover _ | Unmapped _ -> true
    | Already_owned _ | By_contract _ -> false)
;;

let report dispositions =
  let buffer = Buffer.create 1024 in
  let line format = Printf.ksprintf (Buffer.add_string buffer) format in
  line "  ownership recovery: what the provider holds that Terraform does not own\n";
  dispositions
  |> List.iter (function
    | Recover { address; resource_class; found; import_identity } ->
      line
        "    recover: %s %s maps to %s, import identity %s\n"
        resource_class
        found
        address
        import_identity
    | Already_owned { address; found } ->
      line "    already owned: %s is already in this root's state (%s)\n" found address
    | By_contract { resource_class; found } ->
      line
        "    by contract: %s %s is external or durable by contract, so it is not \
         recovered here\n"
        resource_class
        found
    | Cannot_recover { resource_class; found; reason } ->
      line "    CANNOT recover: %s %s -- %s\n" resource_class found reason
    | Unmapped { resource_class; found } ->
      line
        "    UNMAPPED: %s %s has no registry entry, so no Terraform address can own it\n"
        resource_class
        found);
  Buffer.contents buffer
;;

let summary dispositions =
  let recovered =
    List.filter
      (function
        | Recover _ -> true
        | _ -> false)
      dispositions
  in
  let already =
    List.filter
      (function
        | Already_owned _ -> true
        | _ -> false)
      dispositions
  in
  let by_contract =
    List.filter
      (function
        | By_contract _ -> true
        | _ -> false)
      dispositions
  in
  let refused =
    List.filter
      (function
        | Cannot_recover _ | Unmapped _ -> true
        | Recover _ | Already_owned _ | By_contract _ -> false)
      dispositions
  in
  Printf.sprintf
    "%d recoverable, %d already owned, %d not this target's to recover (contract or \
     owner), %d refused"
    (List.length recovered)
    (List.length already)
    (List.length by_contract)
    (List.length refused)
;;
