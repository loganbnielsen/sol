(** INFRA-090: the provider's disk-quota observation, and whether it leaves room for the
    platform's declared minimum. See the module's own comment for the division of knowledge:
    observation is the provider's, the requirement is Sol's, the comparison is policy, and the
    provider's future node behaviour is not modelled. *)

type observation =
  { quota_name : string
  ; limit_gb : int
  ; used_gb : int
  }

(** The quota that governs the storage class the platform asks for. *)
val governing_quota : string

val free_gb : observation -> int

(** Read one quota from a region-describe JSON payload. A quota the payload does not carry is
    an error, never zero. *)
val observation_of_json : ?quota:string -> string -> (observation, string) result

(** e.g. ["SSD_TOTAL_GB 500/500 GiB used (0 GiB free)"]. *)
val describe : observation -> string

(** Sol's policy: [Ok] when the observed free quota covers the declared minimum, otherwise
    [Error] naming the observation, the requirement and which quota to raise. *)
val sufficient : observation:observation -> required_gb:int -> (unit, string) result
