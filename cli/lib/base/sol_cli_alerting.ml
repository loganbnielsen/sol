let qualified_receiver_types = [ "webhook" ]
let normalize s = String.lowercase_ascii (String.trim s)
let receiver_type_qualified typ = List.mem (normalize typ) qualified_receiver_types

let has_prefix ~prefix s =
  let pl = String.length prefix in
  String.length s >= pl && String.equal (String.sub s 0 pl) prefix
;;

let url_is_routable url =
  let u = String.trim url in
  let scheme_len = if has_prefix ~prefix:"https://" u then 8 else 7 in
  (has_prefix ~prefix:"https://" u || has_prefix ~prefix:"http://" u)
  && String.length u > scheme_len
  && u.[scheme_len] <> '/'
;;

let non_empty s = String.trim s <> ""

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
        | Some o when not (non_empty o) ->
          Error
            "`alert_owner` is empty; every required alert must name an accountable owner"
        | Some _ ->
          (match runbook_url with
           | None ->
             Error
               "`alert_runbook_url` is missing; every required alert must link to its \
                first-response runbook"
           | Some r when not (non_empty r) ->
             Error
               "`alert_runbook_url` is empty; every required alert must link to its \
                first-response runbook"
           | Some _ -> Ok ())))
;;
