type command =
  { argv : string list
  ; cwd : string
  }

type recipe =
  { label : string
  ; language : Sol_cli_compat.language
  ; build : command option
  ; launch : command
  ; artifact : string
  ; env : (string * string) list
  }

type plan =
  { builds : command list
  ; launches : recipe list
  }

val plan
  :  root:string
  -> facts:Sol_cli_workspace_model.t
  -> Sol_cli_manifest.service list
  -> (plan, (string * string) list) result

val label : Sol_cli_manifest.service -> string
val build_line : command -> string
val launch_line : command -> string
val dev_registry_url : string
val dev_env : (string * string) list
