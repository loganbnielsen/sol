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

(** [var_file ~cwd ~workspace_root ~flag ~target] is the var file a cloud command
    passes to Terraform, as an absolute path (BUG-057). The [--var-file] [flag] wins
    and is relative to [cwd]; otherwise the target's [terraform_var_file] is relative
    to [workspace_root], so a target resolves the same file from any directory. An
    absolute path is returned unchanged. *)
val var_file
  :  cwd:string
  -> workspace_root:string
  -> flag:string option
  -> target:string option
  -> string option

(** [of_target ~strict ~workspace target] loads [target] and returns its
    variables ({!of_config}) with the resolved target. [strict] (apply and
    destroy, which mutate infrastructure) refuses a target that is not declared,
    so a typo'd one cannot inherit sol.yml's shared defaults. *)
val of_target
  :  strict:bool
  -> workspace:string
  -> string
  -> ((string * string) list * Sol_cli_config.target, string) result

(** [resolved key ~var_files ~vars]: the value a Terraform run gives [key] --
    the last [key=value] in [vars] (the [--var] flags), else the first var file
    that assigns it. Surrounding quotes are dropped; an unreadable var file
    assigns nothing. *)
val resolved : string -> var_files:string list -> vars:string list -> string option
