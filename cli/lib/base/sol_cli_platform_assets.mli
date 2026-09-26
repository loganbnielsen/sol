(** Where Sol's own assets come from (DEC-049).

    Sol reads Sol-owned files at run time: the cloud Terraform roots, the local
    observability dashboards and Alloy template, the platform components' Helm
    values, and the source the migration runner is built from. This module is
    the only place that decides where those live. Commands ask it for an asset
    and never look for Sol's source tree themselves; [internal/ci/check_platform_assets_owner.sh]
    enforces that.

    Every root exposes the same [platform/] tree, so what a consumer gets is a
    path into it, whichever distribution form the root is. *)

(** A resolved asset root. *)
type t

type error =
  | Invalid_sol_home of string
  (** [SOL_HOME] is set but does not name a Sol checkout. An explicit root
        that is wrong is an error; it never falls through to another source. *)
  | Not_found (** No [SOL_HOME], and no Sol checkout above the running binary. *)

val error_to_string : error -> string

(** Resolve the root: an explicit [SOL_HOME] (an empty value counts as unset,
    since [Unix.putenv] cannot unset), then a Sol checkout found by walking up
    from the running binary. *)
val resolve : unit -> (t, error) result

(** [resolve], or print the error with the fix and exit 1. *)
val resolve_or_exit : unit -> t

(** The root directory. For messages and for handing a whole tree to a tool. *)
val dir : t -> string

(** {1 Assets} *)

type cloud_role =
  | Cluster
  | Platform

(** [cloud_root_rel provider role] is the Terraform root's path relative to any
    asset root, e.g. [platform/cloud/aws/cluster]. *)
val cloud_root_rel : Sol_cli_provider.t -> cloud_role -> string

(** The Terraform root for [provider]'s [role]. *)
val cloud_root : t -> Sol_cli_provider.t -> cloud_role -> string

(** [platform/shared/components.json]: the platform components' Helm values. *)
val components_json : t -> string

(** A Grafana dashboard under [platform/shared/observability/dashboards/]. *)
val dashboard : t -> string -> string

(** [platform/shared/observability/alloy/logs.alloy.tftpl]. *)
val alloy_template : t -> string

(** How to obtain the migration runner image. A source checkout builds it from
    itself. *)
type migration_runner = Build_from_source of { context : string }

val migration_runner : t -> migration_runner

(** {1 Checkout discovery}

    Exposed for tests; commands use {!resolve}. *)

(** [true] if [dir] is a Sol source checkout: the two framework sentinels
    [framework/ocaml/sol-svc/lib/dune] and [framework/ocaml/kafka-eio-service/lib/dune]
    exist, and [dir] is not inside a dune [_build] tree (which mirrors them). *)
val is_checkout : string -> bool

(** [find_ancestor pred dir] is the first of [dir] and its ancestors satisfying
    [pred]. *)
val find_ancestor : (string -> bool) -> string -> string option
