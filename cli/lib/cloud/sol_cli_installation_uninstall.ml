open Sol_cli_installation

type plan =
  { removes : prerequisite list
  ; retains : (string * string) list
  ; unmanages_the_zone : bool
  ; dns_confirmation : string option
  }

let unmanages ~zone_in_state zone = (not (owns_the_zone zone)) && zone_in_state

let removal_candidate prerequisite ~created ~zone =
  List.mem prerequisite created && (prerequisite <> Delegated_zone || owns_the_zone zone)
;;

let plan ~prerequisites ~created ~zone_in_state configuration =
  let zone = configuration.zone in
  let keeps_the_zone = not (owns_the_zone zone) in
  let removes =
    List.filter (fun item -> removal_candidate item ~created ~zone) prerequisites
  in
  let zone_retains =
    match zone_domain zone with
    | Some domain when keeps_the_zone ->
      [ ( domain
        , "the zone was supplied by the operator, so Sol did not create it and does not \
           remove it" )
      ; ( domain
        , "the NS records at your registrar live outside every provider API Sol can \
           call, so removing them is yours to do" )
      ]
    | Some domain ->
      [ ( domain
        , "the NS records at your registrar still point at this zone's nameservers; a \
           recreated zone gets different ones" )
      ]
    | None -> []
  in
  let other_retains =
    prerequisites
    |> List.filter (fun item -> not (List.mem item removes))
    |> List.filter_map (fun item ->
      if item = Delegated_zone || item = Public_delegation
      then None
      else
        Some
          ( prerequisite_label item
          , "the durable root does not create it; the operator does, so Sol does not \
             remove it" ))
  in
  let dns_confirmation =
    match zone_domain zone with
    | Some domain when owns_the_zone zone -> Some domain
    | _ -> None
  in
  { removes
  ; retains = zone_retains @ other_retains
  ; unmanages_the_zone = unmanages ~zone_in_state zone
  ; dns_confirmation
  }
;;

let lines (plan : plan) =
  let removes =
    match plan.removes with
    | [] -> [ "nothing durable: this installation owns no account-level resource" ]
    | prerequisites ->
      List.map
        (fun prerequisite ->
           Printf.sprintf "remove  %s" (prerequisite_label prerequisite))
        prerequisites
  in
  let retains =
    List.map (fun (what, why) -> Printf.sprintf "retain  %s -- %s" what why) plan.retains
  in
  let unmanage =
    if plan.unmanages_the_zone
    then
      [ "the durable root's state owns a zone the target says the operator supplied: it \
         is taken out of state first, so the zone survives this uninstall"
      ]
    else []
  in
  let confirmation =
    match plan.dns_confirmation with
    | Some domain ->
      [ Printf.sprintf
          "removing the zone for %s needs its own confirmation, because the delegation \
           at your registrar becomes stale and a recreated zone would have different \
           nameservers: --confirm-dns-zone %s"
          domain
          domain
      ]
    | None -> []
  in
  removes @ retains @ unmanage @ confirmation
;;

let confirmed_dns_zone_matches ~confirmation ~domain =
  match confirmation with
  | Some given -> String.equal (String.trim given) domain
  | None -> false
;;

let refusal_of_unobservable reason =
  Printf.sprintf
    "Sol could not observe what remains (%s), so it does not claim the installation is \
     gone"
    reason
;;

type removal_verification =
  { removed : prerequisite list
  ; present : (prerequisite * string) list
  ; unknown : (prerequisite * string) list
  }

let classify_removal ~removes verdicts =
  let classify (verification : removal_verification) prerequisite =
    match List.assoc_opt prerequisite verdicts with
    | Some (Unmet _) ->
      { verification with removed = prerequisite :: verification.removed }
    | Some Established ->
      { verification with
        present = (prerequisite, "the provider still holds it") :: verification.present
      }
    | Some (Unknown reason) ->
      { verification with unknown = (prerequisite, reason) :: verification.unknown }
    | None ->
      { verification with
        unknown = (prerequisite, "no observation was made") :: verification.unknown
      }
  in
  let classified =
    List.fold_left classify { removed = []; present = []; unknown = [] } removes
  in
  { removed = List.rev classified.removed
  ; present = List.rev classified.present
  ; unknown = List.rev classified.unknown
  }
;;

let removal_established verification =
  verification.present = [] && verification.unknown = []
;;

let verification_lines (verification : removal_verification) =
  let removed =
    List.map
      (fun prerequisite ->
         Printf.sprintf "removed  %s -- observed absent" (prerequisite_label prerequisite))
      verification.removed
  in
  let present =
    List.map
      (fun (prerequisite, why) ->
         Printf.sprintf "NOT removed  %s -- %s" (prerequisite_label prerequisite) why)
      verification.present
  in
  let unknown =
    List.map
      (fun (prerequisite, why) ->
         Printf.sprintf "UNKNOWN  %s -- %s" (prerequisite_label prerequisite) why)
      verification.unknown
  in
  removed @ present @ unknown
;;
