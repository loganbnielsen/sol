type rollout_strategy =
  | Recreate
  | RollingUpdate

type scheduled_concurrency =
  | Allow
  | Forbid
  | Replace

type canary_step =
  | Weight of int
  | Pause of int option

type progressive_delivery =
  | Canary of { steps : canary_step list }
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

type volume_access_mode =
  | ReadWriteOnce
  | ReadOnlyMany
  | ReadWriteMany

type volume =
  { name : string
  ; mount_path : string
  ; size : string
  ; access_mode : volume_access_mode
  }

val volume_access_mode_to_string : volume_access_mode -> string
val volume_access_mode_of_string : string -> (volume_access_mode, string) result

val effective_rollout_of_string
  :  string
  -> (rollout_strategy option * progressive_delivery option, string) result

type t =
  { replicas : int option
  ; availability : Sol_cli_availability.t option
  ; cpu : cpu_quantity option
  ; memory : memory_quantity option
  ; env_config : (string * string) list
  ; secret_keys : string list
  ; volumes : volume list
  ; rollout_strategy : rollout_strategy option
  ; ingress_host : hostname option
  ; ingress_path : ingress_path option
  ; extra_labels : (string * string) list
  ; progressive_delivery : progressive_delivery option
  ; schedule : string option
  ; scheduled_concurrency : scheduled_concurrency option
  ; backoff_limit : int option
  ; calls : string list
  ; topics : string list
  }

val empty : t

type parse_error =
  | Toml_syntax of
      { path : string
      ; message : string
      }
  | Validation of
      { path : string
      ; message : string
      }

val parse_error_to_string : parse_error -> string
val load_result : string -> (t, parse_error) result
