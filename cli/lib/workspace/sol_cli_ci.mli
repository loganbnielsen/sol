type outcome =
  { written : bool
  ; path : string
  }

val target_rel : string
val init_github : force:bool -> cwd:string -> (outcome, string) result
