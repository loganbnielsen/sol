type t =
  { volume_name : string
  ; audience : string
  ; url_env_var : string
  ; mount_path : string
  }

val of_call : callee_k8s_name:string -> audience:string -> url_env_var:string -> t
val token_file : t -> string
val token_file_env_var : t -> string
