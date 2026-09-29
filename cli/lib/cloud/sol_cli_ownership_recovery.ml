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
  | Owned_through of
      { resource_class : string
      ; found : string
      ; owner : string
      ; reason : string
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

let disposition_of
      ~entries
      ~class_rules
      ~descendants
      ~state_addresses
      ~resource_class
      found
  =
  match
    List.filter (fun (entry : entry) -> matches entry ~resource_class ~found) entries
  with
  | [ entry ] ->
    if not (Sol_cli_resource_identity.recoverable entry)
    then
      Cannot_recover
        { resource_class
        ; found
        ; reason = Sol_cli_resource_identity.ownership_reason entry.ownership
        }
    else if List.mem entry.address state_addresses
    then Already_owned { address = entry.address; found }
    else
      Recover
        { address = entry.address
        ; resource_class
        ; found
        ; import_identity = entry.import_identity
        }
  | [] ->
    (match
       List.find_opt
         (fun (rule : Sol_cli_resource_identity.class_rule) ->
            rule.resource_class = resource_class)
         class_rules
     with
     | Some rule ->
       (match rule.ownership with
        | External_by_contract _ -> By_contract { resource_class; found }
        | ownership ->
          Cannot_recover { resource_class; found; reason = ownership_reason ownership })
     | None ->
       (match
          List.find_opt
            (fun (d : Sol_cli_resource_identity.descendant) ->
               d.resource_class = resource_class)
            descendants
        with
        | Some descendant ->
          Owned_through
            { resource_class
            ; found
            ; owner = descendant.owner
            ; reason = descendant.reason
            }
        | None -> Unmapped { resource_class; found }))
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

let dispositions ~entries ~class_rules ~descendants ~state_addresses observations =
  observations
  |> List.concat_map (function
    | Sol_cli_absence.Present { resource_class; found; _ } ->
      List.map
        (disposition_of
           ~entries
           ~class_rules
           ~descendants
           ~state_addresses
           ~resource_class)
        found
    | Sol_cli_absence.Absent _
    | Sol_cli_absence.External _
    | Sol_cli_absence.Not_attributable _
    | Sol_cli_absence.Unobservable _ -> [])
;;

let candidate = function
  | Recover candidate -> Some candidate
  | Already_owned _ | By_contract _ | Owned_through _ | Cannot_recover _ | Unmapped _ ->
    None
;;

let outstanding dispositions =
  dispositions
  |> List.filter (function
    | Recover _ | Cannot_recover _ | Unmapped _ -> true
    | Already_owned _ | By_contract _ | Owned_through _ -> false)
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
    | Owned_through { resource_class; found; owner; reason } ->
      line
        "    owned through: %s %s belongs to %s -- %s\n"
        resource_class
        found
        owner
        reason
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
  let through =
    List.filter
      (function
        | Owned_through _ -> true
        | _ -> false)
      dispositions
  in
  let refused =
    List.filter
      (function
        | Cannot_recover _ | Unmapped _ -> true
        | Recover _ | Already_owned _ | By_contract _ | Owned_through _ -> false)
      dispositions
  in
  Printf.sprintf
    "%d recoverable, %d already owned, %d not this target's to recover (contract or \
     owner), %d refused"
    (List.length recovered)
    (List.length already)
    (List.length by_contract + List.length through)
    (List.length refused)
;;
