val render_spec
  :  workspace:string
  -> ?env:string
  -> ?image:string
  -> release_id:Sol_cli_release_id.t
  -> ?secret_backend:Sol_cli_manifest.secret_backend
  -> Sol_cli_deployment_plan.service_spec
  -> (string * string, string) result
