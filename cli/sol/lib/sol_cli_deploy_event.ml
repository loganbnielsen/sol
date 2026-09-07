(* Structured Loki release-event line for `sol deploy` (OBS-037). Field set
   mirrors Sol_cli_manifest_yaml.render_taxonomy_labels's taxonomy labels
   (workspace/env/domain/service/primitive/release) so a deployed release's
   manifest labels and its deploy-event log line describe the same release
   consistently, plus a fixed `event=deploy` field OBS-038's dashboard query
   filters on to separate deploy markers from ordinary application log
   lines. Pure/testable; the actual HTTP push and Loki-reachability I/O live
   in cli/sol/bin/cmd_deploy_event.ml. *)

type t = {
  workspace : string;
  env       : string;
  domain    : string;
  service   : string;
  primitive : string;
  release   : string;
}

let fields t =
  [ "event",     "deploy"
  ; "workspace", t.workspace
  ; "env",       t.env
  ; "domain",    t.domain
  ; "service",   t.service
  ; "primitive", t.primitive
  ; "release",   t.release
  ]

let message t =
  Printf.sprintf "deployed %s/%s (%s) release %s to workspace %s (%s)"
    t.domain t.service t.primitive t.release t.workspace t.env

(* Push URL resolution (OBS-037). Same explicit-always-wins precedence as
   Sol_cli_status.probe_url, but for a push target instead of a query
   target:
   - an explicit [--loki-push-url] always wins.
   - [Local]/[Self_hosted_durable] both have an in-cluster Loki
     (platform/infra/base/main.tf's [loki_install_local]) that isn't
     Ingress-exposed -- [Auto_detect] tells the caller it's safe to probe
     the live cluster for it (unlike Sol_cli_status's read-only reachability
     check, [sol deploy]'s direct-apply mode already has kubectl/cluster
     access for its own [kubectl apply], so a live probe is strictly more
     useful here than guessing a static default).
   - [External] never has an in-cluster Loki to find (same
     [loki_install_local] condition excludes it) and no existing
     [Sol_cli_config] target field carries an external push URL --
     [Skip reason] explains why nothing was pushed. *)
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
       Skip "the \"external\" observability backend has no configured Loki \
             push URL -- pass --loki-push-url to record this deploy's \
             release event")
