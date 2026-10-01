type plan =
  { removes : Sol_cli_installation.prerequisite list
  ; retains : (string * string) list
  ; unmanages_the_zone : bool
  ; dns_confirmation : string option
  }

let unmanages ~zone_in_state zone =
  (not (Sol_cli_installation.owns_the_zone zone)) && zone_in_state
;;

let plan
      ~prerequisites
      ~zone_in_state
      (configuration : Sol_cli_installation.installation_config)
  =
  let zone = configuration.zone in
  let keeps_the_zone = not (Sol_cli_installation.owns_the_zone zone) in
  let removes =
    List.filter
      (fun prerequisite ->
         prerequisite <> Sol_cli_installation.Delegated_zone
         || Sol_cli_installation.owns_the_zone zone)
      prerequisites
  in
  let retains =
    match Sol_cli_installation.zone_domain zone with
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
  let dns_confirmation =
    match Sol_cli_installation.zone_domain zone with
    | Some domain when Sol_cli_installation.owns_the_zone zone -> Some domain
    | _ -> None
  in
  { removes
  ; retains
  ; unmanages_the_zone = unmanages ~zone_in_state zone
  ; dns_confirmation
  }
;;

let prerequisite_line prerequisite = Sol_cli_installation.prerequisite_label prerequisite

let lines (plan : plan) =
  let removes =
    match plan.removes with
    | [] -> [ "nothing durable: this installation owns no account-level resource" ]
    | prerequisites ->
      List.map
        (fun prerequisite -> Printf.sprintf "remove  %s" (prerequisite_line prerequisite))
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
