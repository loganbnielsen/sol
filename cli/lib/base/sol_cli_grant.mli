val secret_capability : string
val annotation_key : string
val tag : capability:string -> resource:string -> string
val tag_of_secret_key : string -> string
val capability_of_tag : string -> string
val resource_of_tag : string -> string
val encode_tags : string list -> string
val decode_tags : string -> (string list, string) result
