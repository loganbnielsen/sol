val emission_backend
  :  emit_to:string option
  -> backend:string option
  -> store_ref:string option
  -> store_kind:string option
  -> key_prefix:string option
  -> refresh_interval:string option
  -> (Sol_cli_manifest.secret_backend option, string) result
