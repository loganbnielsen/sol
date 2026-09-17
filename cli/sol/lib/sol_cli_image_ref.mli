(** Immutable workload artifact references (FEAT-050).

    A production release and its rollback must refer to the same workload
    bytes. A tag can move; a content digest cannot. This module is the single
    definition of what counts as an immutable reference, so the command
    request, the deployment plan and the profile preflight cannot disagree. *)

(** [is_digest s] is true for [repo@sha256:<64 lowercase hex digits>] with a
    non-empty repository. *)
val is_digest : string -> bool

(** [split_flag_value value] splits a raw [--image-ref] value into an optional
    service name and the reference. [<service>=<ref>] yields [Some service];
    a bare [<ref>] yields [None]. *)
val split_flag_value : string -> string option * string

(** [resolve ~service_names refs] maps parsed [--image-ref] values to
    [service -> reference] overrides for the services actually selected. Every
    reference must be a digest; a named reference must name a selected service;
    a bare reference requires exactly one selected service. Returns [Error msg]
    for the first violation. *)
val resolve
  :  service_names:string list
  -> (string option * string) list
  -> ((string * string) list, string) result

(** [plan_is_immutable images] is true when the list is non-empty and every
    image is a digest reference. *)
val plan_is_immutable : string list -> bool
