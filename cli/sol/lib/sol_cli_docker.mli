val build
  :  tag:string
  -> dockerfile:string
  -> context:string
  -> (unit, Sol_cli_process.error) result

val push : image_ref:string -> (unit, Sol_cli_process.error) result

(** [manifest_exists ~image_ref] is true when the registry resolves
    [image_ref] (a digest or tag) through `docker manifest inspect`. A missing
    reference, a missing docker CLI, or a registry/credential failure all
    return false: the caller fails closed. *)
val manifest_exists : image_ref:string -> bool

val inspect_digest : image_ref:string -> string
