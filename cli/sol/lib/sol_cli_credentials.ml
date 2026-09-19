(* Provider credentials for a lifecycle operation (INFRA-039).

   Sol inherits the ambient environment, which is right for a short command and
   wrong for an operation that runs for hours. HARDEN-002 Run 5 Attempt 5 lost its
   SSO session mid-run: `sol cloud destroy` could not authenticate against a
   billable target, while `aws sts get-caller-identity` still answered for the same
   profile -- the CLI held usable cached role credentials and terraform, which
   needed to refresh, could not.

   Two things follow, and neither is "use longer-lived credentials":

   - credentials are resolved again *per operation*, rather than assuming whatever
     was in the environment when Sol started still works;
   - the resolved principal is reported, so a stage is attributable to an identity
     instead of to whatever the operator's shell happened to hold.

   Resolution goes through `aws configure export-credentials`, which asks the CLI to
   resolve the chain -- including refreshing an SSO session that the CLI can refresh
   and terraform cannot. The result is installed into Sol's own environment, so
   every child (terraform, aws, kubectl) inherits credentials known to be valid now;
   the platform's provider blocks pin no profile, so environment credentials are
   what the AWS SDK uses. *)

type t =
  { access_key_id : string
  ; secret_access_key : string
  ; session_token : string option
  ; principal : string
  }

(* `--format env` rather than `--format json`: the CLI already prints exactly the
   three variables to install, so there is nothing to parse but `export K=V`. *)
let parse_env_format output =
  let lines = String.split_on_char '\n' output in
  let value key =
    let prefix = "export " ^ key ^ "=" in
    let prefix_length = String.length prefix in
    List.find_map
      (fun line ->
         let line = String.trim line in
         if String.length line > prefix_length && String.sub line 0 prefix_length = prefix
         then Some (String.sub line prefix_length (String.length line - prefix_length))
         else None)
      lines
  in
  match value "AWS_ACCESS_KEY_ID", value "AWS_SECRET_ACCESS_KEY" with
  | Some access_key_id, Some secret_access_key ->
    Some (access_key_id, secret_access_key, value "AWS_SESSION_TOKEN")
  | _ -> None
;;

let resolve ~run ~profile =
  let argv =
    match profile with
    | Some profile ->
      [ "aws"
      ; "configure"
      ; "export-credentials"
      ; "--profile"
      ; profile
      ; "--format"
      ; "env"
      ]
    | None -> [ "aws"; "configure"; "export-credentials"; "--format"; "env" ]
  in
  match run argv with
  | None ->
    Error "`aws configure export-credentials` did not run; is the AWS CLI on PATH?"
  | Some output ->
    (match parse_env_format output with
     | None ->
       Error
         "`aws configure export-credentials` produced no credentials (the session may \
          have expired)"
     | Some (access_key_id, secret_access_key, session_token) ->
       let principal =
         match
           run
             [ "aws"; "sts"; "get-caller-identity"; "--query"; "Arn"; "--output"; "text" ]
         with
         | Some output when String.trim output <> "" -> String.trim output
         | _ -> "<unattributed>"
       in
       Ok { access_key_id; secret_access_key; session_token; principal })
;;

let install t =
  Unix.putenv "AWS_ACCESS_KEY_ID" t.access_key_id;
  Unix.putenv "AWS_SECRET_ACCESS_KEY" t.secret_access_key;
  match t.session_token with
  | Some token -> Unix.putenv "AWS_SESSION_TOKEN" token
  | None -> ()
;;

(* The safety-critical message. A destroy that cannot authenticate leaves billable
   infrastructure standing *and* disables the only supported path to remove it, so
   that has to be said, not implied by a failed stage. *)
let unresolved_message ~operation ~profile ~leaves_target_standing ~detail =
  Printf.sprintf
    "cannot resolve AWS credentials before %s: %s\n%s\n%s"
    operation
    detail
    (match profile with
     | Some profile ->
       Printf.sprintf
         "Profile '%s' could not be resolved. If it uses SSO, re-authenticate (for \
          example `aws sso login --profile %s`) and re-run. A lifecycle operation that \
          can run for hours must be able to reacquire its credentials part-way through, \
          which is why they are resolved per operation rather than captured once at \
          start."
         profile
         profile
     | None ->
       "No AWS profile is set. Configure one via AWS_PROFILE or a default profile.")
    (if leaves_target_standing
     then
       "Nothing has been changed. If this was a destroy, the target is STILL STANDING \
        and may still be billing."
     else "Nothing has been changed.")
;;
