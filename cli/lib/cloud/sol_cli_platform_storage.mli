type part =
  { component : string
  ; gib : int
  ; provenance : string
  }

val parts : part list
val minimum_gb : int
val describe : unit -> string
