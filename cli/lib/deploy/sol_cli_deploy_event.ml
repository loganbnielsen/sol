type t =
  { workspace : string
  ; env : string
  ; domain : string
  ; service : string
  ; primitive : string
  ; release_id : Sol_cli_release_id.t
  ; deployment_id : Sol_cli_deployment_id.t
  }

let fields t =
  [ "event", "deploy"
  ; "workspace", t.workspace
  ; "env", t.env
  ; "domain", t.domain
  ; "service", t.service
  ; "primitive", t.primitive
  ; "release", Sol_cli_release_id.to_string t.release_id
  ; "deployment_id", Sol_cli_deployment_id.to_string t.deployment_id
  ]
;;

let message t =
  Printf.sprintf
    "deployed %s/%s (%s) release %s as deployment %s to workspace %s (%s)"
    t.domain
    t.service
    t.primitive
    (Sol_cli_release_id.to_string t.release_id)
    (Sol_cli_deployment_id.to_string t.deployment_id)
    t.workspace
    t.env
;;

type push_url_decision =
  | Explicit of string
  | Auto_detect
  | Skip of string

let resolve_push_url ~backend ~explicit_url =
  match explicit_url with
  | Some url -> Explicit url
  | None ->
    (match (backend : Sol_cli_observability_url.backend) with
     | Local | Self_hosted_durable -> Auto_detect
     | External ->
       Skip
         "the \"external\" observability backend has no configured Loki push URL -- pass \
          --loki-push-url to record this deploy's release event")
;;
