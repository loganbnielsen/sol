open Sol_cli_installation_uninstall

type failure =
  | Destroy_failed of string
  | Retirement_failed of string
  | Verification_failed of string

type outcome =
  | Uninstall_refused of string
  | Uninstall_succeeded of Sol_cli_installation.prerequisite list
  | Uninstall_failed of
      { failure : failure
      ; verification : removal_verification
      }

type deps =
  { release_state_backend : unit -> (unit, string) result
  ; unmanage_zone : unit -> (unit, string) result
  ; destroy : unit -> (unit, string) result
  ; retire_state_backend : unit -> (unit, string) result
  ; observe :
      unit -> (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
  ; warn : string -> unit
  }

let failure_message = function
  | Destroy_failed message ->
    "the durable root's destruction did not complete: " ^ message
  | Retirement_failed message -> "the state backend could not be retired: " ^ message
  | Verification_failed message -> message
;;

let uses_state_backend removes = List.mem Sol_cli_installation.State_backend removes

let summary (verification : removal_verification) =
  match verification.present, verification.unknown with
  | [], [] -> "everything observed absent"
  | present, [] -> Printf.sprintf "%d resource(s) are still present" (List.length present)
  | [], unknown -> Printf.sprintf "%d observation(s) are UNKNOWN" (List.length unknown)
  | present, unknown ->
    Printf.sprintf
      "%d resource(s) are still present and %d observation(s) are UNKNOWN"
      (List.length present)
      (List.length unknown)
;;

let execute ~deps ~plan ~state_backend_in_state ~confirm ~dns_confirmation =
  let verification () = classify_removal ~removes:plan.removes (deps.observe ()) in
  let decide failure_of =
    let verification = verification () in
    if removal_established verification
    then Uninstall_succeeded verification.removed
    else Uninstall_failed { failure = failure_of verification; verification }
  in
  let refused reason = Uninstall_refused reason in
  let release_state_backend () =
    if uses_state_backend plan.removes && state_backend_in_state
    then (
      match deps.release_state_backend () with
      | Ok () -> Ok ()
      | Error message -> Error message)
    else Ok ()
  in
  let preserve () =
    if plan.unmanages_the_zone
    then (
      match deps.unmanage_zone () with
      | Ok () -> Ok ()
      | Error message -> Error message)
    else Ok ()
  in
  let destroy () = if plan.removes = [] then Ok () else deps.destroy () in
  let after_destruction () =
    match destroy () with
    | Error message ->
      deps.warn
        (Printf.sprintf
           "warning: the durable root's destroy did not complete: %s. Whether the \
            installation is gone is decided by the observation below, not by this exit."
           message);
      decide (fun _ -> Destroy_failed message)
    | Ok () ->
      let retirement =
        if uses_state_backend plan.removes then deps.retire_state_backend () else Ok ()
      in
      (match retirement with
       | Error message ->
         deps.warn
           (Printf.sprintf
              "warning: the state backend could not be retired: %s. Whether it is gone \
               is decided by the observation below."
              message)
       | Ok () -> ());
      decide (fun verification ->
        match retirement with
        | Error message -> Retirement_failed message
        | Ok () ->
          Verification_failed ("the installation is not gone: " ^ summary verification))
  in
  let execute_confirmed () =
    match preserve () with
    | Error message ->
      Uninstall_failed
        { failure = Destroy_failed message; verification = verification () }
    | Ok () ->
      (match release_state_backend () with
       | Error message ->
         Uninstall_failed
           { failure = Destroy_failed message; verification = verification () }
       | Ok () -> after_destruction ())
  in
  if not confirm
  then
    refused
      "nothing was removed: removing an installation is destructive, so re-run with \
       --confirm once you intend what the plan above states"
  else (
    match plan.dns_confirmation with
    | Some domain
      when not (confirmed_dns_zone_matches ~confirmation:dns_confirmation ~domain) ->
      refused
        (Printf.sprintf
           "nothing was removed: deleting the Sol-created zone for %s also makes the NS \
            records at your registrar stale, and a recreated zone gets different \
            nameservers, so it needs its own confirmation naming the exact zone: \
            --confirm-dns-zone %s"
           domain
           domain)
    | Some _ | None ->
      if plan.removes = [] && not plan.unmanages_the_zone
      then Uninstall_succeeded []
      else execute_confirmed ())
;;
