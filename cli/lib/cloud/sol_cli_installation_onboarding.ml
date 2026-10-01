type state =
  | Present
  | Absent
  | Partial
  | Indeterminate

type decision =
  | Proceed
  | Offer
  | Refuse
  | Report

let is_unknown = function
  | Sol_cli_installation.Unknown _ -> true
  | Sol_cli_installation.Established | Sol_cli_installation.Unmet _ -> false
;;

let is_unmet = function
  | Sol_cli_installation.Unmet _ -> true
  | Sol_cli_installation.Established | Sol_cli_installation.Unknown _ -> false
;;

let is_established = function
  | Sol_cli_installation.Established -> true
  | Sol_cli_installation.Unmet _ | Sol_cli_installation.Unknown _ -> false
;;

let state_of_verdicts verdicts =
  let unresolved = Sol_cli_installation.unresolved verdicts in
  if unresolved = []
  then Present
  else if List.exists (fun (_, verdict) -> is_unmet verdict) unresolved
  then
    if List.exists (fun (_, verdict) -> is_established verdict) verdicts
    then Partial
    else Absent
  else Indeterminate
;;

let decision ~interactive = function
  | Present -> Proceed
  | Indeterminate -> Report
  | Absent | Partial -> if interactive then Offer else Refuse
;;

let lines_of text = String.split_on_char '\n' text
let blank = [ "" ]

let unresolved_lines verdicts =
  match Sol_cli_installation.unresolved verdicts with
  | [] -> [ "  nothing: every durable prerequisite is established" ]
  | unresolved -> lines_of (Sol_cli_installation.summary unresolved)
;;

let unknown_lines verdicts =
  match List.filter (fun (_, verdict) -> is_unknown verdict) verdicts with
  | [] -> [ "  nothing" ]
  | unknown -> lines_of (Sol_cli_installation.summary unknown)
;;

let automated_lines configuration =
  let zone_lines =
    match configuration.Sol_cli_installation.zone with
    | Sol_cli_installation.No_zone -> []
    | Sol_cli_installation.Service_zone { domain; ownership = Sol_created } ->
      [ Printf.sprintf
          "  create the DNS zone for %s, or adopt the zone that is already there rather \
           than create a second one with different nameservers, and write the NS \
           delegation itself when the zone that publishes %s is in this account"
          domain
          domain
      ]
    | Sol_cli_installation.Service_zone { domain; ownership = User_supplied } ->
      [ Printf.sprintf
          "  leave the DNS zone for %s alone: the target declares it yours, so Sol never \
           creates or removes it"
          domain
      ]
    | Sol_cli_installation.Service_zone { domain; ownership = Externally_delegated } ->
      [ Printf.sprintf
          "  leave DNS alone: %s is published outside this installation, and the \
           delegation is yours to make"
          domain
      ]
  in
  [ "  reconcile the durable installation root, which keeps a Terraform state of its own:"
  ; "    its state backend and its locking, and the durable resources it declares"
  ]
  @ zone_lines
;;

let external_lines configuration =
  match configuration.Sol_cli_installation.zone with
  | Sol_cli_installation.Service_zone { domain; ownership = Sol_created } ->
    [ "  One action may be required from you:"
    ; Printf.sprintf
        "    when the zone that publishes %s is not in this account, add the exact NS \
         records Sol prints at that zone; Sol then waits for the delegation and confirms \
         it from a public resolver, never from written configuration"
        domain
    ]
  | Sol_cli_installation.Service_zone
      { domain; ownership = User_supplied | Externally_delegated } ->
    [ "  No action is required from you for DNS:"
    ; Printf.sprintf
        "    the delegation for %s is yours to make, and Sol does not wait on it"
        domain
    ]
  | Sol_cli_installation.No_zone ->
    [ "  No DNS action is required: this target serves no domain." ]
;;

let report_lines ~target ~configuration verdicts =
  let heading =
    match state_of_verdicts verdicts with
    | Partial -> Printf.sprintf "Sol is only partly installed for %s:" target
    | Absent -> Printf.sprintf "Sol is not installed for %s yet:" target
    | Present -> Printf.sprintf "The installation for %s is already established:" target
    | Indeterminate ->
      Printf.sprintf "Sol could not confirm the installation for %s:" target
  in
  [ heading ]
  @ blank
  @ [ "  what Sol observed at the provider, never inferred from configuration:" ]
  @ unresolved_lines verdicts
  @ (match List.filter (fun (_, verdict) -> is_unknown verdict) verdicts with
     | [] -> []
     | unknown ->
       [ Printf.sprintf
           "  (%d of these are UNKNOWN because Sol could not look at them; an \
            unobservable prerequisite is never reported as missing, DEC-052)"
           (List.length unknown)
       ])
  @ blank
  @ [ "  the installation the target declares:" ]
  @ Sol_cli_installation.resolved_configuration_to_lines configuration
  @ blank
  @ [ "  Sol does this for you:" ]
  @ automated_lines configuration
  @ blank
  @ external_lines configuration
;;

let refusal_lines ~target ~because verdicts =
  [ Printf.sprintf
      "Sol is not installed for %s, and %s, so Sol will not set it up and will not \
       continue as if it were there."
      target
      because
  ]
  @ blank
  @ [ "  missing:" ]
  @ unresolved_lines verdicts
  @ blank
  @ [ "Set the installation up once, then run this deploy again:"
    ; Printf.sprintf "  sol cloud bootstrap %s --apply" target
    ]
;;

let still_unresolved_lines ~target verdicts =
  [ Printf.sprintf
      "The installation for %s is still not established after reconciling the durable \
       root, so this run stops rather than continue against a prerequisite it could not \
       establish:"
      target
  ]
  @ blank
  @ unresolved_lines verdicts
  @ blank
  @ [ Printf.sprintf "  observe it with: sol cloud bootstrap %s" target ]
;;

let undeclared_lines ~target ~reason =
  [ Printf.sprintf
      "This target declares no Sol installation for %s, so Sol cannot tell whether one \
       exists: %s"
      target
      reason
  ]
  @ blank
  @ [ "A target Sol provisions for declares its installation — `state_bucket`, the \
       provider identities, and who owns the domain — and those declarations are what \
       Sol observes and reconciles."
    ]
;;

let indeterminate_lines ~target verdicts =
  [ Printf.sprintf
      "Sol could not observe the installation for %s, so this run reports it neither \
       established nor absent (DEC-052: an unobservable answer is never promoted to \
       healthy)."
      target
  ]
  @ blank
  @ [ "  Sol could not look at:" ]
  @ unknown_lines verdicts
  @ blank
  @ [ "Observe it with credentials that can read the durable resources:"
    ; Printf.sprintf "  sol cloud bootstrap %s" target
    ]
;;

let observed_lines ~target =
  [ Printf.sprintf
      "Sol observed the installation for %s at the provider: every durable prerequisite \
       is established, so the installation is not what stopped this run."
      target
  ]
;;

let environment_guidance_lines ~target =
  [ "The environment for this target is not usable from here. When it does not exist yet,"
  ; "create it — network, cluster, database and platform — with:"
  ; Printf.sprintf "  sol cloud apply %s" target
  ; "then name the context that command prints as this target's `kube_context`. When it"
  ; "does exist, check that its context is in your kubeconfig and that this target's"
  ; "identity can reach the cluster: Sol never falls back to whatever kubectl is"
  ; "currently pointed at (DEC-020)."
  ]
;;

let present_lines ~target =
  observed_lines ~target @ blank @ environment_guidance_lines ~target
;;

let established_lines ~target =
  [ Printf.sprintf
      "The installation for %s is established. Its durable prerequisites outlive every \
       environment, and destroying an environment never removes them."
      target
  ]
;;
