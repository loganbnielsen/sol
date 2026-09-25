(** REFAC-095: the table-shaped knowledge Sol needs about a provider, selected in
    one place. {!capabilities_of} is the only provider match; it has no wildcard,
    so a new provider does not compile until it declares its own capabilities,
    and nothing inherits another provider's behaviour. Cluster access, retention
    and non-Terraform residue are not here yet (REFAC-096, REFAC-097). *)

(** The StorageClass Sol establishes as the cluster's only default, and the
    block-storage CSI driver that must provide it. *)
type platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

type t =
  { platform_root : string (** The platform Terraform root, relative to the Sol home. *)
  ; platform_address : string -> string
    (** A platform resource's address inside that root. *)
  ; backend_config :
      Sol_cli_config.target
      -> bucket:string
      -> object_key:string
      -> (string list, string) result
    (** [-backend-config] values for a state object in the target's bucket. *)
  ; cluster_access_role_arn : Sol_cli_config.target -> (string option, string) result
    (** The role a caller assumes to reach the cluster, where the provider has one. *)
  ; platform_storage : platform_storage
  ; own_vars :
      Sol_cli_config.target
      -> workspace:string
      -> (string * string) list
      -> (string * string) list
    (** Adds the target fields only this provider's root declares to [shared]. *)
  ; profile_vars : production:bool -> production_postgres:bool -> (string * string) list
    (** Profile-derived variables, placed ahead of every other variable. *)
  ; root_declared_vars :
      has_postgres:bool
      -> production_postgres:bool
      -> ecr_repositories:(unit -> (string, string) result)
      -> ((string * string) list, string) result
    (** Variables the root declares that Sol derives from the workspace. *)
  ; destroy_guard_vars : final_snapshot:string option -> (string * string) list
    (** The Destroy policy's variables: deletion guards lowered, and the final
      snapshot kept when [final_snapshot] names one. *)
  ; bootstrap_matchers : Sol_cli_terraform_plan.matcher list
    (** The bootstrap-access mechanism's Terraform identity. *)
  ; bootstrap_scope : Sol_cli_terraform.scope
  ; reconciliation_scope : string list -> Sol_cli_terraform.scope
    (** The bootstrap mechanism plus the given guarded addresses. *)
  ; guarded_addresses : string list
    (** Resources whose deletion guard destroy lowers, by declared address. *)
  ; cloud_ready_expectation : string
    (** What the substrate readiness check means, in its failure's words. *)
  ; production_qualified : bool
    (** Whether the production profile is qualified on this provider. *)
  ; sol_keys : string list
    (** REFAC-098: keys of the target's provider block that Sol consumes itself
        (identity, backend locking), so they are not passed through as [-var]s. *)
  ; state_locking : string option
    (** The provider-block key naming the state lock, where the backend does not
        lock natively. *)
  ; scoped_identities : string list
    (** The provider-block keys naming the production profile's scoped identities. *)
  }

(** Each provider's own record, for that provider's modules. *)
val aws : t

val gcp : t
val capabilities_of : Sol_cli_provider.t -> t
