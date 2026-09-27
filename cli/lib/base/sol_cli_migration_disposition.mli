type t =
  | Expand
  | Contract

val to_string : t -> string
val of_file_content : string -> (t, string) result
val read_file : path:string -> (t, string) result
