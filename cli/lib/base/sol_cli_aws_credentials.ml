type t =
  { access_key_id : string
  ; secret_access_key : string
  ; session_token : string option
  ; principal : string
  }

let parse_env_format output =
  let lines = String.split_on_char '\n' output in
  let value key =
    let prefix = "export " ^ key ^ "=" in
    let prefix_length = String.length prefix in
    lines
    |> List.find_map (fun line ->
      let line = String.trim line in
      if String.length line > prefix_length && String.sub line 0 prefix_length = prefix
      then Some (String.sub line prefix_length (String.length line - prefix_length))
      else None)
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
         | output ->
           Option.value (Sol_cli_string.non_blank_opt output) ~default:"<unattributed>"
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
