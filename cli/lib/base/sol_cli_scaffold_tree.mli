type rule =
  | Write
  | Skip_if_exists
  | Patch_modules of string

val kinds : string list
val plan : root:string -> kind:string -> (string list, string) result
val text : root:string -> kind:string -> rel:string -> (string, string) result

val copy
  :  root:string
  -> kind:string
  -> dest:string
  -> vars:(string -> (string * string) list)
  -> rule:(string -> rule)
  -> (string list, string) result
