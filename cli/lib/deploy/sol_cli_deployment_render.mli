val render_spec
  :  workspace:string
  -> ?env:string
  -> ?image:string
  -> release_id:Sol_cli_release_id.t
  -> Sol_cli_deployment_plan.service_spec
  -> (Sol_cli_manifest.bundle, string) result
