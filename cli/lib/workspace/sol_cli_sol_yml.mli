type outcome =
  | Declared
  | Language_added
  | Already_declared

type plan

val outcome : plan -> outcome

val plan
  :  root:string
  -> name:string
  -> dir:string
  -> language:Sol_cli_compat.language
  -> (plan, string) result

val commit : plan -> (outcome, string) result
