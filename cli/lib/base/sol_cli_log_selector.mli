type t =
  { workspace : string
  ; domain : string
  ; service : string
  }

val unit : t -> string
val unit_release : t -> release_id:string -> string
