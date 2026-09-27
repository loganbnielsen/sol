type t =
  | Local of
      { image_tag : string
      ; cluster_registry : string
      }
  | Customer_direct of
      { image_tag : string
      ; registry : string
      }
  | Customer_gitops of
      { image_tag : string
      ; registry : string
      }
  | Sol_hosted of
      { image_tag : string
      ; registry : string
      }

val local_defaults : image_tag:string -> t

val customer_cloud_defaults
  :  registry:string
  -> image_tag:string
  -> emit_to:string option
  -> unit
  -> (t, string) result

val image_tag : t -> string
val registry : t -> string
val default_secret_backend : t -> Sol_cli_manifest.secret_backend

val resolve_secret_backend
  :  ?explicit:Sol_cli_manifest.secret_backend
  -> t
  -> Sol_cli_manifest.secret_backend

val to_env_config : name:string -> t -> Sol_cli_deployment_plan.env_config
