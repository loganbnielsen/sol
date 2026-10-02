let qualified_receiver_types = [ "webhook" ]
let normalize s = String.lowercase_ascii (String.trim s)
let receiver_type_qualified typ = List.mem (normalize typ) qualified_receiver_types

let url_is_routable url =
  let u = String.trim url in
  let scheme_len =
    if String.starts_with ~prefix:"https://" u
    then 8
    else if String.starts_with ~prefix:"http://" u
    then 7
    else 0
  in
  scheme_len > 0 && String.length u > scheme_len && u.[scheme_len] <> '/'
;;

let validate ~receiver_type ~receiver_url ~owner ~runbook_url =
  match receiver_type with
  | None ->
    Error
      "no alert receiver is configured; set `alert_receiver_type: webhook` and \
       `alert_receiver_url: <endpoint>` on the target so required alerts reach a named \
       owner"
  | Some typ when not (receiver_type_qualified typ) ->
    Error
      (Printf.sprintf
         "alert receiver type %S is not qualified for this profile (qualified: %s)"
         (String.trim typ)
         (String.concat ", " qualified_receiver_types))
  | Some _ ->
    (match receiver_url with
     | None ->
       Error
         "`alert_receiver_url` is missing; the configured alert receiver needs an \
          endpoint"
     | Some url when not (url_is_routable url) ->
       Error
         (Printf.sprintf
            "`alert_receiver_url` %S is not a routable http(s) URL with a host"
            (String.trim url))
     | Some _ ->
       (match owner with
        | None ->
          Error
            "`alert_owner` is missing; every required alert must name an accountable \
             owner"
        | Some _ ->
          (match runbook_url with
           | None ->
             Error
               "`alert_runbook_url` is missing; every required alert must link to its \
                first-response runbook"
           | Some _ -> Ok ())))
;;
