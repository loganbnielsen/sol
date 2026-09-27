val remove_if_present : string -> (unit, string) result
val remove_reporting : string -> unit
val remove_tree : string -> (unit, string) result
val mkdir_p : ?perm:int -> string -> (unit, string) result
val write_atomic : ?perm:int -> string -> string -> (unit, string) result

val with_temp_file
  :  prefix:string
  -> suffix:string
  -> string
  -> (string -> 'a)
  -> ('a, string) result

val copy_tree : exclude:string list -> src:string -> dst:string -> (unit, string) result
