(** The release record (DEC-018, FEAT-067): what was deployed, from what, and
    how it was scoped. Recorded immutably in the target's cluster so a later
    rollback can restore it and an operator can audit it.

    A record never stores secret *values*; it stores key names only. *)

type workload =
  { domain : string
  ; name : string
  ; image : string
  ; config_keys : string list
  ; secret_keys : string list
  }

type t =
  { release_id : string
  ; created_at : string
  ; workspace : string
  ; target : string
  ; mode : string
  ; git_commit : string
  ; git_dirty : bool
  ; requested_scope : string
  ; workloads : workload list
  ; migrations : string list
  }

(** UTC, second precision, lexicographically sortable. *)
val rfc3339_utc : float -> string

(** [<YYYYMMDDtHHMMSSz>-<commit>] — lowercase and DNS-safe, because it becomes
    part of a ConfigMap name. *)
val generate_release_id : now:float -> commit:string -> string

(** Lowercase a value and replace anything a Kubernetes label value forbids, so
    it can be used for lookup. The exact text is preserved in the record body.
    Label *values* may contain [\_], which is why this is not used for names;
    object names go through [Sol_cli_kubernetes_name.sanitize_name]. *)
val sanitize_label : string -> string

val configmap_name : t -> string
val current_configmap_name : workspace:string -> string

(** Build a record from a deployment plan. [target] is the target path for
    [sol deploy] or ["local"] for [sol up]; [mode] is the same distinction in
    short form. *)
val of_plan
  :  workspace:string
  -> target:string
  -> mode:string
  -> git_commit:string
  -> git_dirty:bool
  -> Sol_cli_deployment_plan.t
  -> t

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result

(** The immutable per-release ConfigMap, as JSON (kubectl accepts JSON). *)
val to_configmap_json : t -> string

(** The mutable pointer ConfigMap naming the current release for a workspace. *)
val to_current_configmap_json : t -> string

(** Parse [kubectl get configmap -l … -o json]; items with no valid record are
    skipped rather than failing the listing. *)
val parse_kubectl_list : Yojson.Safe.t -> (t list, string) result

(** An aligned table of [ID / COMMIT / SCOPE / CREATED / TARGET], newest
    first. *)
val format_table : t list -> string

(** Source provenance. ["unknown"] / [false] outside a git checkout. *)
val git_commit : unit -> string

val git_dirty : unit -> bool
