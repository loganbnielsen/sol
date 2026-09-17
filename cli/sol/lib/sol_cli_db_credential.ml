(* HARDEN-002 (run 1): the database master password a provider root needs when it
   provisions Postgres.

   The password is a bootstrap credential, so it must come from the operator's
   secret store, out of band, and must never appear in an argument vector (Sol
   records the terraform command line in its run log), in a plan, in an output,
   or in the release record. `TF_VAR_db_password` satisfies all of that: terraform
   reads it from the inherited environment, which Sol does not log.

   What this module refuses, before any infrastructure mutation:
   - creating Postgres with no credential source at all (which used to send the
     module's empty default to AWS and fail the whole apply with
     "InvalidParameterValue: Invalid master password" *after* the cluster had
     been built);
   - a password passed via `--var`, because the value would be written to the run
     log verbatim.

   The provider module carries its own precondition on the database resource as
   the defence that does not depend on Sol being the caller. *)

let provider_creates_postgres = function
  | Sol_cli_provider.Aws -> true
  | _ -> false
;;

(* [vars] are terraform ["key=value"] strings, as the caller builds them. *)
let var key vars =
  List.find_map
    (fun entry ->
       match String.index_opt entry '=' with
       | Some i when String.sub entry 0 i = key ->
         Some (String.sub entry (i + 1) (String.length entry - i - 1))
       | _ -> None)
    vars
;;

let truthy = function
  | Some v -> String.lowercase_ascii (String.trim v) = "true"
  | None -> false
;;

type source =
  | Not_needed (** this invocation does not create Postgres *)
  | Environment (** TF_VAR_db_password carries it *)
  | Command_line (** passed with --var; always refused *)
  | Missing

let source ~provider ~vars ~tf_var_env =
  if not (provider_creates_postgres provider && truthy (var "create_rds" vars))
  then Not_needed
  else if Option.is_some (var "db_password" vars)
  then Command_line
  else (
    match tf_var_env with
    | Some v when String.trim v <> "" -> Environment
    | _ -> Missing)
;;

let check ~provider ~vars ~tf_var_env =
  match source ~provider ~vars ~tf_var_env with
  | Not_needed | Environment -> Ok ()
  | Command_line ->
    Error
      "refusing a database master password passed with --var: Sol records the terraform \
       command line in its run log, so the value would be written to a file. Supply it \
       out of band instead: TF_VAR_db_password=<from your secret store> sol cloud apply \
       <target>"
  | Missing ->
    Error
      "this target provisions Postgres (create_rds = true) but no database master \
       password is available. Supply it out of band from your secret store, e.g.\n\
      \      TF_VAR_db_password=\"$(your-secret-tool get sol-db-password)\" sol cloud \
       apply <target>\n\
      \  Sol never writes it to a plan, output, log or release record, and the provider \
       module rejects an empty or weak password rather than provisioning a passwordless \
       database."
;;
