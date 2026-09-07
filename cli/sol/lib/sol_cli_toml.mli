type rollout_strategy = Recreate | RollingUpdate

(** A single step in an Argo Rollouts canary strategy.
    [Weight n]  sets the traffic weight percentage to [n].
    [Pause None] pauses indefinitely (requires manual promotion).
    [Pause (Some s)] pauses for [s] seconds then auto-promotes. *)
type canary_step =
  | Weight of int
  | Pause  of int option

(** Progressive delivery strategy for Argo Rollouts.
    [Canary]     uses weighted traffic-shifting steps.
    [Blue_green] uses two Services (active + preview) with manual promotion. *)
type progressive_delivery =
  | Canary     of { steps : canary_step list }
  | Blue_green

type cpu_quantity
type memory_quantity
type hostname
type ingress_path

val cpu_quantity_of_string : string -> (cpu_quantity, string) result
val memory_quantity_of_string : string -> (memory_quantity, string) result
val hostname_of_string : string -> (hostname, string) result
val ingress_path_of_string : string -> (ingress_path, string) result

val cpu_quantity_to_string : cpu_quantity -> string
val memory_quantity_to_string : memory_quantity -> string
val hostname_to_string : hostname -> string
val ingress_path_to_string : ingress_path -> string

type t = {
  replicas             : int option;
  cpu                  : cpu_quantity option;
  memory               : memory_quantity option;
  env_config           : (string * string) list;
  secret_keys          : string list;
  rollout_strategy     : rollout_strategy option;
  ingress_host         : hostname option;
  ingress_path         : ingress_path option;
  extra_labels         : (string * string) list;
  progressive_delivery : progressive_delivery option;
  (** Cron schedule for [-fn] services, e.g. ["0 * * * *"]. Read from
      [[service] schedule] in sol.toml. [None] means "use default". *)
  schedule             : string option;
  (** Kafka topic names owned by this event/service directory.  Read from
      [[service] topics] in sol.toml.  Used by [discover_topics] to collect
      topics without scanning OCaml source files. *)
  topics               : string list;
}

val empty : t

(** Typed errors returned by [load_result]. *)
type parse_error =
  | Toml_syntax of { path : string; message : string }
  | Validation  of { path : string; message : string }

val parse_error_to_string : parse_error -> string

(** Load and parse a sol.toml file. Returns [Ok empty] if the file does not
    exist. Returns [Error _] for malformed TOML or validation errors. *)
val load_result : string -> (t, parse_error) result

(** Load and parse a sol.toml file. Returns [empty] if the file does not exist.
    Compatibility wrapper around [load_result]. Raises [Failure] with a
    descriptive message on parse or validation errors:
    - Unknown rollout_strategy values (only "Recreate" and "RollingUpdate" accepted).
    - extra_labels keys starting with "sol.dev/" (reserved namespace).
    - Unknown [infra.rollout] strategy values (only "canary" and "blue-green" accepted).
    - Canary strategy with an empty steps list or weights outside 0..100. *)
val load : string -> t
