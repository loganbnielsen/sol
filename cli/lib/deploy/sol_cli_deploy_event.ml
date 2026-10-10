type t =
  { workspace : string
  ; env : string
  ; domain : string
  ; service : string
  ; primitive : string
  ; release_id : Sol_cli_release_id.t
  }

(* The identity fields a deploy event shares with the workload taxonomy. The key
   names come from the taxonomy's single owner; the event carries one value per
   key it knows how to project, so a label that is workload-only is simply
   absent. `observability_identity` is the same list the workload labels and
   `SOL_*` env vars are rendered from, and the release-timeline dashboard joins
   the event line to a workload stream on `workspace`, `domain` and `service`. *)
let identity_field (t : t) = function
  | "workspace" -> Some t.workspace
  | "env" -> Some t.env
  | "domain" -> Some t.domain
  | "service" -> Some t.service
  | "primitive" -> Some t.primitive
  | "release" -> Some (Sol_cli_release_id.to_string t.release_id)
  | _ -> None
;;

let identity_fields t =
  Sol_cli_manifest.observability_identity
  |> List.filter_map (fun (label, _) ->
    Option.map (fun value -> label, value) (identity_field t label))
;;

let fields t = ("event", "deploy") :: identity_fields t

let message t =
  Printf.sprintf
    "deployed %s/%s (%s) release %s to workspace %s (%s)"
    t.domain
    t.service
    t.primitive
    (Sol_cli_release_id.to_string t.release_id)
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
    (match (backend : Sol_cli_observability_backend.backend) with
     | Local | Self_hosted_durable -> Auto_detect
     | External ->
       Skip
         "the \"external\" observability backend has no configured Loki push URL -- pass \
          --loki-push-url to record this deploy's release event")
;;
