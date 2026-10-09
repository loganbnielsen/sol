(* Positive Kubernetes workload ownership. Ownership is the live object's
   [metadata.uid] equalling the UID Sol captured when it applied that object; nothing
   here infers ownership from a declaration, a label, a name or a namespace
   (docs/architecture/ownership.md). This module is the single decision the plan
   reports and the removal paths enforce, so they cannot disagree. *)

type identity =
  { resource : string (* the Kubernetes resource, e.g. "deployment" *)
  ; namespace : string
  ; name : string
  }

(* What the release record says Sol applied for an identity: the UID captured at
   apply, or none. A record written before UID capture carries no evidence. *)
type evidence = string option

(* What Sol observed of the live object. Absence and unobservability are distinct: "I
   looked and it is not there" is not "I could not look". *)
type live =
  | Live_absent
  | Live_present of string
  | Live_unobservable of string

let identity_equal a b =
  String.equal a.resource b.resource
  && String.equal a.namespace b.namespace
  && String.equal a.name b.name
;;

let recorded_uid (owned : Sol_cli_release_id.owned_object list) (id : identity) : evidence
  =
  owned
  |> List.find_map (fun (o : Sol_cli_release_id.owned_object) ->
    if
      String.equal o.resource id.resource
      && String.equal o.namespace id.namespace
      && String.equal o.name id.name
    then Some o.uid
    else None)
;;

(* The one ownership decision: a live object is Sol's only while its UID is exactly
   the recorded one. A fresh UID means something else now occupies the name. *)
let owns ~(recorded : evidence) ~(live_uid : string) =
  match recorded with
  | Some recorded_uid -> String.equal recorded_uid live_uid
  | None -> false
;;

(* A declared workload, classified against its recorded evidence and live object. *)
type declared =
  | Create (* no live object and no recorded UID: Sol never applied one here *)
  | Owned_unchanged (* the live object is exactly the one Sol applied *)
  | Live_not_owned (* a live object is present, but not the one Sol recorded *)
  | Recorded_gone (* Sol recorded applying one, and it is no longer live *)
  | Declared_unobservable of string (* the live object could not be observed *)

let classify_declared ~(recorded : evidence) (live : live) : declared =
  match live with
  | Live_unobservable reason -> Declared_unobservable reason
  | Live_absent ->
    (match recorded with
     | Some _ -> Recorded_gone
     | None -> Create)
  | Live_present live_uid ->
    if owns ~recorded ~live_uid then Owned_unchanged else Live_not_owned
;;

(* A live workspace object the plan does not declare. It may be removed only while its
   UID matches the recorded evidence; without that match it is retained. *)
type surplus =
  | Surplus_removable
  | Surplus_retained

let classify_surplus ~(recorded : evidence) ~(live_uid : string) : surplus =
  if owns ~recorded ~live_uid then Surplus_removable else Surplus_retained
;;

(* Observe one live object's UID. [Live_unobservable] carries the provider's own reason
   so a caller does not have to reinterpret it. *)
let observe ~(ctx : Sol_cli_kube_destination.context) (id : identity) : live =
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:id.resource
      ~name:id.name
      ~namespace:id.namespace
      ~output:"jsonpath={.metadata.uid}"
  with
  | Ok output ->
    let uid = String.trim output.Sol_cli_process.stdout in
    if String.equal uid ""
    then
      Live_unobservable (Printf.sprintf "%s %s has no metadata.uid" id.resource id.name)
    else Live_present uid
  | Error e ->
    (match Sol_cli_kubectl.classify e with
     | Sol_cli_kubectl.Not_found -> Live_absent
     | Sol_cli_kubectl.No_resource_type ->
       Live_unobservable (Printf.sprintf "the %s kind is not served" id.resource)
     | _ -> Live_unobservable (Sol_cli_process.error_to_string e))
;;
