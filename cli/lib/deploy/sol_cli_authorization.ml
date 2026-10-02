type grant =
  { unit : string
  ; capability : string
  ; resource : string
  }

let compare_grant a b =
  let by_unit = String.compare a.unit b.unit in
  if by_unit <> 0
  then by_unit
  else (
    let by_capability = String.compare a.capability b.capability in
    if by_capability <> 0 then by_capability else String.compare a.resource b.resource)
;;

let normalize grants = List.sort_uniq compare_grant grants

let grant_to_string grant =
  Printf.sprintf "%s \xe2\x86\x92 %s/%s" grant.unit grant.capability grant.resource
;;

type deployed_state =
  | Deployed of grant list
  | Unobservable of string

type plan =
  { keep : grant list
  ; additions : grant list
  ; removals : grant list
  ; held : grant list
  ; held_reason : string
  ; notes : string list
  }

let without all excluded = List.filter (fun grant -> not (List.mem grant excluded)) all

let compute ~desired ~current ~deployed =
  let desired = normalize desired in
  let current = normalize current in
  let additions = without desired current in
  let stale = without current desired in
  match deployed with
  | Unobservable reason ->
    let held_reason = Printf.sprintf "deployed state unobservable: %s" reason in
    { keep = normalize (desired @ stale)
    ; additions
    ; removals = []
    ; held = stale
    ; held_reason
    ; notes = [ Printf.sprintf "held %d grant(s): %s" (List.length stale) held_reason ]
    }
  | Deployed deployed ->
    let deployed = normalize deployed in
    let removals, held =
      List.partition (fun grant -> not (List.mem grant deployed)) stale
    in
    { keep = normalize (desired @ held)
    ; additions
    ; removals
    ; held
    ; held_reason = "still required by a deployed workload"
    ; notes = []
    }
;;

let render plan =
  List.map (fun grant -> "+ " ^ grant_to_string grant) plan.additions
  @ List.map (fun grant -> "- " ^ grant_to_string grant) plan.removals
  @ List.map
      (fun grant -> Printf.sprintf "~ %s (%s)" (grant_to_string grant) plan.held_reason)
      plan.held
;;
