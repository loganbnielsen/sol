(* FEAT-065: the one bridge between discovery and the scope vocabulary.

   [Sol_cli_deployment_scope] answers *what a name means* against a neutral
   [named list]; [Sol_cli_manifest] answers *what is on disk*. This module is
   the single place the two meet. Every command that accepts [--scope] resolves
   through {!resolve}, so no two commands can disagree about what a name means —
   the property FEAT-065's invariant asks for.

   Resolution happens once, at the command boundary, and the result carries the
   resolved services forward. After this point no command sees a selector string
   again. Whether an empty result is an error is still the caller's policy: the
   scope vocabulary is deliberately neutral about emptiness, and a read-only
   command must be able to report "nothing matched" rather than fail. *)

type resolved =
  { request : Sol_cli_deployment_scope.request
  ; scope : Sol_cli_deployment_scope.t
  ; services : Sol_cli_manifest.service list
  }

let named_of_service (svc : Sol_cli_manifest.service) : Sol_cli_deployment_scope.named =
  { Sol_cli_deployment_scope.domain = svc.Sol_cli_manifest.domain
  ; name = svc.Sol_cli_manifest.name
  ; kind =
      (match svc.Sol_cli_manifest.primitive with
       | Sol_cli_manifest.Svc -> Sol_cli_deployment_scope.Service
       | Sol_cli_manifest.Worker -> Sol_cli_deployment_scope.Worker
       | Sol_cli_manifest.Fn -> Sol_cli_deployment_scope.Function)
  }
;;

let named_of_services services = List.map named_of_service services

(* The resolver canonicalises a match to discovery's own name, so a selected
   unit always corresponds to exactly one discovered service. Filter discovery
   order rather than the resolver's order so the resolved set keeps the
   workspace's own layout. *)
let service_is_selected
      (selected : Sol_cli_deployment_scope.named list)
      (svc : Sol_cli_manifest.service)
  =
  List.exists
    (fun (unit_ : Sol_cli_deployment_scope.named) ->
       Sol_cli_deployment_scope.equal_name svc.Sol_cli_manifest.domain unit_.domain
       && Sol_cli_deployment_scope.equal_name svc.Sol_cli_manifest.name unit_.name)
    selected
;;

let services_of_selection services selected =
  List.filter (service_is_selected selected) services
;;

let resolve ?(what = "--scope") scope_value services =
  match Sol_cli_deployment_scope.parse_request ~what scope_value with
  | Error _ as err -> err
  | Ok request ->
    (match
       Sol_cli_deployment_scope.resolve ~what request (named_of_services services)
     with
     | Error _ as err -> err
     | Ok (scope, Sol_cli_deployment_scope.Selected selected) ->
       Ok { request; scope; services = services_of_selection services selected }
     | Ok (scope, Sol_cli_deployment_scope.Empty) -> Ok { request; scope; services = [] })
;;

let is_empty (resolved : resolved) = resolved.services = []

(* DEC-041: `omit` means "not in this target's default set", so the omission is
   applied *after* the scope is resolved, not as a filter on the inventory — the
   request kind decides whether an omitted unit is dropped or allowed back in, and
   the resolver has already canonicalised the names. *)
type omission =
  { selected : Sol_cli_manifest.service list
  ; excluded : Sol_cli_manifest.service list
  ; included : Sol_cli_manifest.service list
  }

let apply_omission ~is_omitted (resolved : resolved) =
  let omitted, kept = List.partition is_omitted resolved.services in
  match resolved.request with
  | Sol_cli_deployment_scope.Unit_named _ ->
    (* Naming a unit explicitly is intent about this invocation (DEC-036), so it
       may name one back in. The profile preflight still runs on it, which is what
       keeps this from re-including a unit that cannot run here at all. *)
    { selected = resolved.services; excluded = []; included = omitted }
  | Sol_cli_deployment_scope.Whole_workspace | Sol_cli_deployment_scope.Whole_domain _ ->
    (* Neither names a unit, so an omitted one is never swept back in as
       collateral: `--scope payments` must not redeploy something the target
       deliberately leaves out. *)
    { selected = kept; excluded = omitted; included = [] }
;;
