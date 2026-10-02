type t =
  { reconciler : Sol_cli_provider_capabilities.authorization_reconciler
  ; principal_matches : principal:string -> (unit, string) result
  ; assumption : unit -> ((string * string) list, string) result
  }

let declared reconciler =
  match reconciler with
  | Sol_cli_provider_capabilities.Reconciler_role value | Reconciler_service_account value
    -> value
;;

let of_target (target : Sol_cli_config.target) =
  let capabilities = Sol_cli_provider_capabilities.capabilities_of target.provider in
  let refuse detail =
    Error
      (Printf.sprintf
         "target %s cannot run the authorization reconciler: %s. Workload cloud \
          authorization is reconciled only as its own fenced identity (DEC-062 rule 2); \
          Sol never falls back to the ambient or deploy identity."
         target.name
         detail)
  in
  match capabilities.authorization_reconciler target with
  | Error message -> Error message
  | Ok reconciler ->
    (match Sol_cli_config.provider_field target "deploy_role_arn" with
     | Some deploy when String.equal deploy (declared reconciler) ->
       refuse
         "the reconciler identity names the deploy identity, and the reconciler must be \
          separate from it"
     | Some _ | None ->
       Ok
         { reconciler
         ; principal_matches =
             (fun ~principal ->
               capabilities.authorization_principal_matches reconciler ~principal)
         ; assumption = (fun () -> capabilities.authorization_assumption reconciler)
         })
;;

let describe identity =
  match identity.reconciler with
  | Sol_cli_provider_capabilities.Reconciler_role arn -> "reconciler role " ^ arn
  | Reconciler_service_account account -> "reconciler service account " ^ account
;;

let caller_is_reconciler identity ~principal = identity.principal_matches ~principal
let environment identity = identity.assumption ()
