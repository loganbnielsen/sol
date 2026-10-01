let retire ~run (configuration : Sol_cli_installation.installation_config) =
  let bucket = configuration.state_bucket in
  match
    run [ "gcloud"; "storage"; "rm"; "--recursive"; "--quiet"; "gs://" ^ bucket ^ "/" ]
  with
  | Sol_cli_installation.Observed _ -> Ok ()
  | Sol_cli_installation.Absent reason -> Error reason
  | Sol_cli_installation.Unobservable reason -> Error reason
;;
