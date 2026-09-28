type declared_certificate =
  { certificate : string
  ; namespace : string
  ; provenance : string
  }

val certificates : declared_certificate list
val describe : unit -> string
