(* One plan-classification and assertion mechanism for destructive applies
   (HARDEN-004 step 3, REFAC-091).

   The problem this exists for: a destructive lifecycle must not perform an
   unapproved constructive operation merely to make the target destroyable. A
   whole-root `terraform apply` creates anything in configuration and absent from
   state, so on a half-built target the step that is supposed to make destruction
   possible can create the very cluster it was asked to remove (FND-0044), and a
   `-target` still pulls in dependencies and reconciles the whole resource, so an
   unasserted targeted apply can create too (FND-0030).

   So every apply reachable from destroy is planned first, the plan is classified
   from Terraform's own resource changes -- addresses and actions, never log text
   -- and the apply only runs when every change is inside that phase's allowlist.

   The classification is deliberately strict: a plan that cannot be read, or that
   contains an action string we do not recognise, is REFUSED rather than allowed.
   "We could not tell" must never mean "fine". *)

type action =
  | Create
  | Update
  | Delete
  | Replace
    (* ForceNew drift: Terraform reports ["delete","create"] or
       ["create","delete"]. Either ordering is a replacement -- a create on the
       destroy path -- so both collapse here. *)
  | Read
  | No_op
  | Unknown of string list (* an action list we do not recognise: always refused *)

type change =
  { address : string
  ; resource_type : string
  ; mode : string (* "managed" or "data" *)
  ; action : action
  }

(** How a rule identifies the resources it governs. [Type] exists for a
    mechanism Terraform owns inside a module whose internal address is
    module-version-dependent (the AWS bootstrap access-policy association); the
    rule is still narrow -- it names one resource type in a root that has exactly
    one such resource -- but it cannot be an address, and the plan assertion is
    what enforces the boundary there. *)
type matcher =
  | Exact of string
  | Type of string

type rule =
  { matches : matcher list
  ; allows : action list
  ; reason : string
  }

type policy =
  { phase : string
  ; rules : rule list
  }

let action_of_raw = function
  | [ "no-op" ] -> No_op
  | [ "read" ] -> Read
  | [ "create" ] -> Create
  | [ "update" ] -> Update
  | [ "delete" ] -> Delete
  | [ "delete"; "create" ] | [ "create"; "delete" ] -> Replace
  | raw -> Unknown raw
;;

let action_to_string = function
  | Create -> "create"
  | Update -> "update"
  | Delete -> "delete"
  | Replace -> "replace"
  | Read -> "read"
  | No_op -> "no-op"
  | Unknown raw -> "unrecognised action [" ^ String.concat "," raw ^ "]"
;;

let ( let* ) = Result.bind

(* Parse `terraform show -json <saved plan>` into the resource changes it holds.
   A plan that does not carry a `resource_changes` array is not a plan we can
   assert on, so it is an error -- and the caller refuses. *)
let changes_of_plan_json json : (change list, string) result =
  try
    let open Yojson.Safe.Util in
    let document = Yojson.Safe.from_string json in
    match member "resource_changes" document with
    | `List items ->
      List.fold_left
        (fun acc item ->
           let* acc = acc in
           let address = member "address" item |> to_string_option in
           let resource_type = member "type" item |> to_string_option in
           let mode = member "mode" item |> to_string_option in
           let raw_actions =
             match member "change" item with
             | `Assoc _ as change ->
               (match member "actions" change with
                | `List raw ->
                  List.filter_map
                    (function
                      | `String s -> Some s
                      | _ -> None)
                    raw
                | _ -> [])
             | _ -> []
           in
           match address, resource_type, mode with
           | Some address, Some resource_type, Some mode ->
             Ok
               ({ address; resource_type; mode; action = action_of_raw raw_actions }
                :: acc)
           | _ ->
             Error
               "a resource change in the plan has no address, type or mode, so it cannot \
                be asserted")
        (Ok [])
        items
      |> Result.map List.rev
    | _ -> Error "the plan JSON carries no `resource_changes` array"
  with
  | Yojson.Json_error message -> Error ("invalid plan JSON: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    Error ("unexpected plan JSON shape: " ^ message)
;;

let matches matcher change =
  match matcher with
  | Exact address -> change.address = address
  | Type kind -> change.resource_type = kind
;;

(* [no-op] anywhere is fine; a data-source [read] is fine. Everything else needs
   a rule whose matcher covers the change and whose allowlist holds the action. *)
let permitted policy change =
  match change.action with
  | No_op -> true
  | Read when change.mode = "data" -> true
  | action ->
    List.exists
      (fun rule ->
         List.exists (fun matcher -> matches matcher change) rule.matches
         && List.mem action rule.allows)
      policy.rules
;;

let violations policy changes =
  List.filter_map
    (fun change ->
       if permitted policy change
       then None
       else (
         let action = action_to_string change.action in
         let in_scope =
           List.exists
             (fun rule ->
                List.exists (fun matcher -> matches matcher change) rule.matches)
             policy.rules
         in
         Some
           (if in_scope
            then
              Printf.sprintf
                "%s phase: %s on %s (%s) is not an action this phase permits"
                policy.phase
                action
                change.address
                change.resource_type
            else
              Printf.sprintf
                "%s phase: %s on %s (%s) is outside this phase's scope"
                policy.phase
                action
                change.address
                change.resource_type)))
    changes
;;

type apply_failure =
  | Plan_failed of string (* the plan command itself failed: refuse *)
  | Plan_unreadable of string (* show/parse/classification failure: refuse *)
  | Refused of string list (* classified changes outside the allowlist *)
  | Apply_failed of string (* the apply ran and failed *)

let apply_failure_to_string = function
  | Plan_failed message -> message
  | Plan_unreadable message -> message
  | Refused violations -> "refused before apply: " ^ String.concat "; " violations
  | Apply_failed message -> message
;;

let was_refused = function
  | Refused _ -> true
  | Plan_failed _ | Plan_unreadable _ | Apply_failed _ -> false
;;

(* plan -> read the plan -> classify -> refuse or apply the saved plan. The apply
   receives the *saved plan file*, so what ran is what was asserted; an apply
   that re-planned with the same arguments could differ from the asserted plan. *)
let guarded_apply ~policy ~plan ~show_plan ~apply_plan () =
  match plan () with
  | Error message ->
    Error
      (Plan_failed (Printf.sprintf "%s: terraform plan failed: %s" policy.phase message))
  | Ok plan_file ->
    (match show_plan plan_file with
     | Error message ->
       Error
         (Plan_unreadable
            (Printf.sprintf "%s: the plan could not be read: %s" policy.phase message))
     | Ok json ->
       (match changes_of_plan_json json with
        | Error message ->
          Error (Plan_unreadable (Printf.sprintf "%s: %s" policy.phase message))
        | Ok changes ->
          (match violations policy changes with
           | [] ->
             (match apply_plan plan_file with
              | Ok () -> Ok ()
              | Error message ->
                Error (Apply_failed (Printf.sprintf "%s: %s" policy.phase message)))
           | violations -> Error (Refused violations))))
;;
