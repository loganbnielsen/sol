val merged_values_yaml
  :  assets:Sol_cli_platform_assets.t
  -> component:string
  -> profile:string
  -> (string, string) result

val versions : assets:Sol_cli_platform_assets.t -> ((string * string) list, string) result
