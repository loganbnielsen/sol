(* The read-only live workload delta [sol plan] prints. Every ownership decision comes
   from Sol_cli_workload_ownership.owns (the live UID equals the UID captured at apply);
   nothing is inferred from a declaration, a label, a name or a namespace
   (docs/architecture/ownership.md). The plan reports; it never removes. *)

type delta =
  | Deferred of string
  | Delta of
      { declared :
          (Sol_cli_workload_ownership.identity * Sol_cli_workload_ownership.declared) list
      ; surplus :
          (Sol_cli_workload_ownership.identity * Sol_cli_workload_ownership.surplus) list
      ; unobservable : (string * string) list
      }

let compare_identity
      (a : Sol_cli_workload_ownership.identity)
      (b : Sol_cli_workload_ownership.identity)
  =
  let by_resource = String.compare a.resource b.resource in
  if by_resource <> 0
  then by_resource
  else (
    let by_namespace = String.compare a.namespace b.namespace in
    if by_namespace <> 0 then by_namespace else String.compare a.name b.name)
;;

let compute
      ~(ctx : Sol_cli_kube_destination.context)
      ~(workspace : string)
      ~(evidence : (Sol_cli_release_id.owned_object list, string) result)
      ~(declared : Sol_cli_workload_ownership.identity list)
  : delta
  =
  match evidence with
  | Error reason -> Deferred reason
  | Ok owned ->
    let declared =
      List.map
        (fun (id : Sol_cli_workload_ownership.identity) ->
           let recorded = Sol_cli_workload_ownership.recorded_uid owned id in
           let live = Sol_cli_workload_ownership.observe ~ctx id in
           id, Sol_cli_workload_ownership.classify_declared ~recorded live)
        declared
    in
    let listing = Sol_cli_rollback.observe_workspace_workloads ~ctx ~workspace in
    let declared_ids = List.map fst declared in
    let surplus =
      listing.objects
      |> List.filter (fun (o : Sol_cli_rollback.live_object) ->
        not (List.exists (Sol_cli_workload_ownership.identity_equal o.id) declared_ids))
      |> List.map (fun (o : Sol_cli_rollback.live_object) ->
        let recorded = Sol_cli_workload_ownership.recorded_uid owned o.id in
        o.id, Sol_cli_workload_ownership.classify_surplus ~recorded ~live_uid:o.uid)
      |> List.sort (fun (a, _) (b, _) -> compare_identity a b)
    in
    Delta { declared; surplus; unobservable = listing.unobservable }
;;

let identity_to_string (id : Sol_cli_workload_ownership.identity) =
  Printf.sprintf "%s %s/%s" id.resource id.namespace id.name
;;

let declared_label = function
  | Sol_cli_workload_ownership.Create -> "create"
  | Owned_unchanged -> "owned, unchanged"
  | Live_not_owned -> "live, not owned"
  | Recorded_gone -> "recorded, gone"
  | Declared_unobservable _ -> "unobservable"
;;

let surplus_label = function
  | Sol_cli_workload_ownership.Surplus_removable -> "removable"
  | Surplus_retained -> "retained"
;;

let declared_detail (d : Sol_cli_workload_ownership.declared) =
  match d with
  | Create -> "no live object; Sol will create it"
  | Owned_unchanged -> "the live object is the one Sol applied"
  | Live_not_owned -> "a live object is present but not the one Sol recorded; retained"
  | Recorded_gone -> "Sol recorded applying it; it is absent now"
  | Declared_unobservable reason -> reason
;;

let surplus_detail (s : Sol_cli_workload_ownership.surplus) =
  match s with
  | Surplus_removable -> "the live UID matches the recorded UID"
  | Surplus_retained -> "no recorded UID match; retained"
;;

let to_string = function
  | Deferred reason ->
    Printf.sprintf
      "Live workload delta deferred: %s. Nothing is inferred about live objects Sol \
       could not observe.\n"
      reason
  | Delta { declared; surplus; unobservable } ->
    let declared_lines =
      List.map
        (fun (id, d) ->
           Printf.sprintf
             "  %-16s %s (%s)"
             (declared_label d)
             (identity_to_string id)
             (declared_detail d))
        declared
    in
    let surplus_lines =
      List.map
        (fun (id, s) ->
           Printf.sprintf
             "  %-16s %s (%s)"
             (surplus_label s)
             (identity_to_string id)
             (surplus_detail s))
        surplus
    in
    let unobservable_lines =
      List.map
        (fun (resource, reason) ->
           Printf.sprintf "  %-16s %s: %s" "unobservable" resource reason)
        unobservable
    in
    let sections =
      [ "Live workload delta (recorded UID evidence):", declared_lines
      ; "Surplus (live workspace objects the plan does not declare):", surplus_lines
      ; "Not observed (nothing is inferred about these):", unobservable_lines
      ]
      |> List.filter_map (fun (title, lines) ->
        match lines with
        | [] -> None
        | lines -> Some (String.concat "\n" (title :: lines)))
    in
    (match sections with
     | [] -> "Live workload delta: none."
     | sections -> String.concat "\n\n" sections)
;;
