(** Neutral key/value Terraform variables for the target's provider root: the
    shared target fields (region/cluster_name/base_domain, alert routing), the
    fields only that provider's root declares, the target's provider block, the
    profile-derived variables, and the variables the root declares that Sol
    derives from the workspace (for AWS, [create_rds], [rds_multi_az] and
    [ecr_repositories], auto-derived from every service under [app/]). Which
    root declares what comes from {!Sol_cli_provider_capabilities}. Terraform
    CLI syntax ("key=value", "-var=...") is not this module's concern — see
    {!Sol_cli_terraform.kv_args}. *)
val of_config
  :  workspace:string
  -> Sol_cli_config.t
  -> ((string * string) list, string) result
