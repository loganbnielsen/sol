(** Where Sol's own assets come from (DEC-049).

    Sol reads Sol-owned files at run time: the cloud Terraform roots, the local
    observability dashboards and Alloy template, the platform components' Helm
    values, and the migration runner. This module is the only place that
    decides where those live. Commands ask it for an asset and never look for
    Sol's source tree themselves; [internal/ci/check_platform_assets_owner.sh]
    enforces that.

    A source checkout and an installed release are two distribution forms of
    one product. Both expose the same [platform/] tree, so what a consumer gets
    is a path into it, whichever form the root is. *)

(** A resolved asset root. *)
type t

(** The two distribution forms. *)
type form =
  | Checkout (** A Sol source checkout: the development form. *)
  | Installed of { version : string }
  (** An installed release's bundle, [<prefix>/share/sol/<version>/]. *)

type error =
  | Invalid_sol_home of string
  (** [SOL_HOME] is set but names neither a checkout nor a bundle. An explicit
      root that is wrong is an error; it never falls through to another
      source. *)
  | Bundle_version_mismatch of
      { dir : string
      ; bundle : string
      ; binary : string option
      } (** [SOL_HOME] names the bundle of a release other than this binary. *)
  | Missing_bundle of
      { expected : string
      ; version : string
      } (** A release binary whose own bundle is not installed beside it. *)
  | Not_found (** A development build with no [SOL_HOME] and no checkout above it. *)

val error_to_string : error -> string

(** [resolve_from ~sol_home ~exe_dir ~release_version] is DEC-049's order, as a
    pure function of its inputs:
    + a non-empty [sol_home]: a checkout, or a bundle whose [VERSION] equals
      [release_version]; anything else is an error;
    + a release binary ([release_version = Some v]): its own bundle at
      [<exe_dir>/../share/sol/<v>/], or [Missing_bundle]. A release never walks
      up to a checkout, whose assets would not be its release's;
    + a development build: the nearest checkout above [exe_dir]. *)
val resolve_from
  :  sol_home:string option
  -> exe_dir:string
  -> release_version:string option
  -> (t, error) result

(** [resolve_from] for this process: [$SOL_HOME] (empty counts as unset, since
    [Unix.putenv] cannot unset), the running binary's directory, and
    {!Sol_cli_build_info.release_version}. *)
val resolve : unit -> (t, error) result

(** [resolve], or print the error with the fix and exit 1. *)
val resolve_or_exit : unit -> t

(** The root directory. For messages and for handing a whole tree to a tool. *)
val dir : t -> string

val form : t -> form

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

(** How to obtain the migration runner image. A checkout builds it from itself.
    An installed release uses the image published with it, named by digest in
    the bundle's [migration-runner-image] file, and nothing else. *)
type migration_runner =
  | Build_from_source of { context : string }
  | Published of string

val migration_runner : t -> (migration_runner, string) result

(** {1 Checkout discovery}

    Exposed for tests; commands use {!resolve}. *)

(** [true] if [dir] is a Sol source checkout: the two framework sentinels
    [framework/ocaml/sol-svc/lib/dune] and
    [framework/ocaml/kafka-eio-service/lib/dune] exist, and [dir] is not inside
    a dune [_build] tree (which mirrors them). *)
val is_checkout : string -> bool

(** [find_ancestor pred dir] is the first of [dir] and its ancestors satisfying
    [pred]. *)
val find_ancestor : (string -> bool) -> string -> string option
