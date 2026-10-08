type value =
  | Text of string
  | Texts of string list
  | Null

val displayable : string -> ((string * value) list, string) result
val line : string * value -> string
val raw : string -> name:string -> (string option, string) result

(** A text-valued output, decoded. [raw] renders whatever JSON type the output
    holds; a command, a context or a URL is text and has to be read as text, not
    as its JSON encoding. A non-text value is an error rather than a rendering. *)
val text : string -> name:string -> (string option, string) result
