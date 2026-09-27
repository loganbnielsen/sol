(** The concrete wiring of [sol cloud plan|apply|destroy] for one target
    (REFAC-139, part D): the dependencies {!Sol_cli_cloud_apply.execute} and
    {!Sol_cli_cloud_destroy.execute} run on, and the plan and destroy-preview
    sequences. The command resolves the request, calls these and renders the
    typed outcome. Nothing here exits; progress is reported through
    {!Sol_cli_report}.

    Directories are Terraform working directories
    ({!Sol_cli_terraform_workdir}); [*_backend] values are backend configs. *)

(** The flag that confirms a guarded removal (INFRA-074), named once. *)
val confirm_guarded_removal_flag : string

(** [init ~assets run_log ~provider ~role backend]: materialize the working
    directory for that state from Sol's assets (DEC-050) and run
    [terraform init]. A materialization failure is [Refused]; an init failure is
    [Terraform_failed]. *)
val init
  :  assets:Sol_cli_platform_assets.t
  -> Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> string list
  -> (unit, Sol_cli_cloud_apply.failure) result

(** [sol cloud plan] after the cloud root is initialized: the cloud root's plan,
    then the platform's prerequisites and substrate, each planned or reported as
    deferred. An unavailable cluster credential is a refusal, never a deferred
    phase. *)
val plan
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> platform_dir:string
  -> platform_backend:string list
  -> var_files:string list
  -> vars:string list
  -> (unit, Sol_cli_cloud_apply.failure) result

(** The dependencies of {!Sol_cli_cloud_apply.execute} for one target.
    Provider-specific steps come from the target's cluster (REFAC-096). *)
val apply_deps
  :  assets:Sol_cli_platform_assets.t
  -> confirm_ecr_removal:bool
  -> provider:Sol_cli_provider.t
  -> pname:string
  -> run_log:Sol_cli_run_log.t
  -> infra_dir:string
  -> platform_dir:string
  -> platform_backend:string list
  -> var_files:string list
  -> vars:string list
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> target_cfg:Sol_cli_config.target
  -> (Sol_cli_cluster.t, (string * string) list, unit) Sol_cli_cloud_apply.deps

(** [sol cloud destroy]'s read-only preview: the platform root's destroy plan
    when install outputs let it be wired (reported as deferred otherwise), then
    the cloud root's. *)
val destroy_preview
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> var_files:string list
  -> vars:string list
  -> (unit, string) result

(** The provider's retention and residue steps for one destroy (REFAC-097). *)
val destruction
  :  run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> var_files:string list
  -> vars:string list
  -> Sol_cli_destruction.t

(** The dependencies of {!Sol_cli_cloud_destroy.execute} for one target. *)
val destroy_deps
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> cloud_backend:string list
  -> var_files:string list
  -> vars:string list
  -> retention:Sol_cli_cloud_lifecycle.destroy_retention
  -> destruction:Sol_cli_destruction.t
  -> Sol_cli_cloud_destroy.deps
