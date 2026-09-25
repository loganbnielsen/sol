(* The provider root's variables for a target (REFAC-095: moved out of
   [Sol_cli_config], whose provider matches it replaced with
   [Sol_cli_provider_capabilities]).

   HARDEN-002 (run 1): these are the variables of the *provider* root
   (`cli/platform/infra/<provider>`), which is what `sol cloud plan/apply/destroy`
   drives. A target field must only appear here if that root declares it --
   otherwise terraform fails the whole command with "a variable named X was
   assigned on the command line, but the root module does not declare a variable
   of that name", which is what `cluster_issuer` used to do. `cluster_issuer` (and
   the other base-platform settings) belong to `cli/platform/infra/base`, applied
   separately with its own variables; the Renderer consumes the target value for
   ingress annotations, so the field stays meaningful without being routed to the
   provider root.

   GCP (first live attempt): the rule was stated correctly but applied to only one
   provider. `create_rds`, `rds_multi_az`, `ecr_repositories` and `workspace_name`
   were routed to *every* target's root, and the GCP root declares none of them --
   so the first live GCP attempt died with four "Value for undeclared variable"
   errors before terraform could plan anything at all. Routing a variable a root
   does not declare is an error, not a no-op, which is why which root declares
   what is a provider capability rather than a detail of this function.

   Order matters, because Terraform's last `-var` wins and
   [Sol_cli_config.vars_with_profile_precedence] decides which side comes last:
   the shared and provider-own fields, then the target's provider block (so a
   target can override them), then the profile-derived variables and the
   root-declared ones ahead of everything. *)

let add_opt k = function
  | None -> Fun.id
  | Some v -> fun xs -> (k, v) :: xs
;;

let of_config ~workspace cfg =
  match Sol_cli_config.target cfg with
  | None -> Error "target missing"
  | Some (target : Sol_cli_config.target) ->
    let capabilities = Sol_cli_provider_capabilities.capabilities_of target.provider in
    let shared =
      []
      |> add_opt "region" (Some target.region)
      |> add_opt "cluster_name" target.cluster_name
      |> add_opt "base_domain" target.base_domain
      |> add_opt "alert_receiver_type" target.alert_receiver_type
      |> add_opt "alert_receiver_url" target.alert_receiver_url
      |> add_opt "alert_owner" target.alert_owner
      |> add_opt "alert_runbook_url" target.alert_runbook_url
    in
    let provider_own = capabilities.own_vars target ~workspace shared in
    let vars =
      List.assoc_opt (Sol_cli_provider.to_string target.provider) target.provider_fields
      |> Option.value ~default:[]
      |> List.rev_append provider_own
    in
    let has_postgres =
      Sol_cli_config.resources cfg
      |> List.exists (fun (r : Sol_cli_config.resource) -> r.typ = Some "postgres")
    in
    let production = target.profile = Some Sol_cli_profile.Production_single_region in
    let production_postgres = has_postgres && production in
    (* Profile-derived, so they are placed where [vars_with_profile_precedence]
       makes them win over any provider-field or --var value: the profile's claims
       (the cluster shape INFRA-030 sized, a production database that stays
       protected) must not be weakened by a caller. sol cloud destroy lowers the
       deletion guard deliberately, later in the argument list. *)
    let vars = capabilities.profile_vars ~production ~production_postgres @ vars in
    (* A provider that declares a database and needs a credential is not silently
       skipped: `TF_VAR_db_password` is what carries it, the root itself refuses a
       missing one, and [Sol_cli_sensitive_vars] refuses it on the command line
       (SEC-010). *)
    Result.map
      (fun declared -> declared @ vars)
      (capabilities.root_declared_vars
         ~has_postgres
         ~production_postgres
         ~ecr_repositories:Sol_cli_config.ecr_repositories_var)
;;
