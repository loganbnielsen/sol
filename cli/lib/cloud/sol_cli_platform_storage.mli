(** INFRA-090: Sol's own declaration of the persistent disk the platform needs.

    The provider observes the quota; this says what Sol will ask of it. A *minimum*, treated as
    a floor by the lifecycle check, with each part carrying the declaration it came from. *)

type part =
  { component : string
  ; gib : int
  ; provenance : string
  }

val parts : part list

(** The sum of {!parts}: what the platform's PersistentVolumeClaims ask for at least. *)
val minimum_gb : int

(** e.g. ["prometheus server 8 GiB; prometheus alertmanager 2 GiB; loki (single binary) 10 GiB"]. *)
val describe : unit -> string
