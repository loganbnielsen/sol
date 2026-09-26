(** Where Terraform runs (DEC-050).

    The Terraform roots under [platform/cloud/] are immutable Sol-owned program
    assets: in a read-only installed release they cannot be written, and in a
    checkout they must not be. Terraform needs a working directory it can write
    ([.terraform/], and [errored.tfstate] when a state push fails). So each
    Terraform state gets its own working directory, and every invocation
    materializes the authoritative assets into it before Terraform runs.

    {v
      <Sol state>/terraform/<provider>-<role>-<identity>/
        platform/cloud/...            the assets, rewritten from the source on every run
        platform/shared/...           (the shared module reads ../../../shared)
        platform/cloud/<provider>/<role>/   Terraform's -chdir
          .terraform/                 Terraform's own, kept between runs
          errored.tfstate             a failed state push: never touched by Sol
        .sol-materialized             the files Sol wrote last time
    v}

    [<Sol state>] is {!Sol_cli_state.dir} ([$XDG_DATA_HOME/sol], else
    [~/.local/share/sol]), beside the supervisor's operation records, so it
    survives a crash of Sol. [<identity>] digests the provider, the role and the
    backend configuration -- exactly the remote state this directory works on --
    so different targets, and a target's cluster and platform roots, never share
    one; the backend configuration itself is passed to [terraform init] unchanged.

    This is not a cache. The assets are authoritative: each run rewrites every
    source file from them and removes a source file it wrote before that the
    assets no longer have. It never deletes or overwrites anything it did not
    write, so Terraform's failure artifacts survive for recovery. *)

(** The working directory's root for one Terraform state. Pure. *)
val dir
  :  provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> backend_config:string list
  -> string

(** Terraform's [-chdir] for that state: [dir]'s copy of the provider's root.
    Pure, so a caller can check the previous operation before anything is
    written. *)
val chdir
  :  provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> backend_config:string list
  -> string

(** A name Terraform leaves in its working directory at run time, never an
    asset: [.terraform], [errored.tfstate], [crash.log], lock info, local state. *)
val is_runtime_artifact : string -> bool

(** [materialize ~assets ~provider ~role ~backend_config] writes the assets'
    [platform/cloud/] and [platform/shared/] into the state's working directory
    and returns its [chdir]. Runtime artifacts in the source are never copied, and
    nothing in the working directory that Sol did not write is ever removed. *)
val materialize
  :  assets:Sol_cli_platform_assets.t
  -> provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> backend_config:string list
  -> (string, string) result
