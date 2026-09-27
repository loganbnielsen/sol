(* sol deploy's release-event push to Loki (OBS-037). Kept out of
   cmd_deploy.ml since it's the only place in cli/bin that needs
   obs-eio/obs-loki-eio -- cmd_migrate.ml is the only other module that
   scopes an Eio_main.run to a single command's I/O rather than wrapping
   the whole binary, and this follows the same pattern. *)

let loki_local_port = 13100
let loki_remote_port = 3100
let loki_namespace = "monitoring"
let loki_service = "loki"

(* Mirrors cmd_migrate.ml's cluster_pg_exists -- a live kubectl probe, not a
   guess, since sol deploy's direct-apply mode already has cluster access. *)
let cluster_loki_exists ~ctx () =
  Result.is_ok
    (Sol_cli_kubectl.get
       ~ctx
       ~resource:"svc"
       ~name:loki_service
       ~namespace:loki_namespace
       ~output:"name")
;;

(* Mirrors cmd_migrate.ml's auto_forward_pg: spawn a temporary kubectl
   port-forward, poll until it accepts a TCP connection, register at_exit
   cleanup. sol deploy exits shortly after this call either way (this runs
   from the tail of a real, non-dry-run, non-emit-to apply), so at_exit
   teardown is sufficient -- same precedent, not a new one. Returns the
   local push URL, or [None] if the forward never started or never became
   ready in time (never raises; a failed forward here must not fail the
   deploy). *)
let auto_forward_loki ~ctx () =
  Printf.eprintf "Forwarding loki (cluster) -> localhost:%d ...\n%!" loki_local_port;
  match
    Sol_cli_kubectl.temporary_port_forward
      ~ctx
      ~service:loki_service
      ~namespace:loki_namespace
      ~local_port:loki_local_port
      ~remote_port:loki_remote_port
  with
  | Ok () -> Some (Printf.sprintf "http://localhost:%d" loki_local_port)
  | Error (Not_started e) ->
    Printf.eprintf
      "warning: could not start kubectl port-forward for loki: %s\n%!"
      (Sol_cli_process.error_to_string e);
    None
  | Error Not_ready ->
    Printf.eprintf "warning: loki port-forward did not become ready in time\n%!";
    None
  | Error (Readiness_check_failed msg) ->
    Printf.eprintf "warning: loki port-forward readiness check failed: %s\n%!" msg;
    None
;;

(* Resolves Sol_cli_deploy_event.resolve_push_url's decision into an actual
   URL, performing the I/O (kubectl probe + port-forward) that decision
   layer deliberately leaves to its caller. Never raises; prints an
   explanatory note/warning and returns [None] for every "nothing to push
   to" outcome. *)
let resolve_url ~ctx ~backend ~explicit_url =
  match Sol_cli_deploy_event.resolve_push_url ~backend ~explicit_url with
  | Sol_cli_deploy_event.Explicit url -> Some url
  | Sol_cli_deploy_event.Auto_detect ->
    if cluster_loki_exists ~ctx ()
    then auto_forward_loki ~ctx ()
    else (
      Printf.eprintf
        "note: no in-cluster Loki service found (svc/%s -n %s); skipping deploy-event \
         log push. Pass --loki-push-url to record this deploy's release event anyway.\n\
         %!"
        loki_service
        loki_namespace;
      None)
  | Sol_cli_deploy_event.Skip reason ->
    Printf.eprintf "note: %s\n%!" reason;
    None
;;

(* Push one event. Failure to push must never fail the deploy (OBS-037) --
   Obs_eio already routes ordinary backend exceptions raised while closing
   the span to its own on_backend_error hook (default: print to stderr,
   don't propagate), so this try/with is a second, redundant safety net
   over synchronous failures outside that path (e.g. Obs_loki.create
   rejecting a malformed --loki-push-url). Cancellation and fatal runtime
   exceptions are deliberately re-raised, not swallowed -- same exclusion
   list Obs_eio.report_backend_error itself uses. *)
let deploy_event_stream_labels =
  [ Obs_loki.stream_label_exn "workspace"
  ; Obs_loki.stream_label_exn "domain"
  ; Obs_loki.stream_label_exn "primitive"
  ; Obs_loki.stream_label_exn "release"
  ]
;;

(* [service] is the deployed service's real name (Obs_eio.create's built-in
   stream label), matching every real app pod's own convention -- deploy
   events land in that service's own Loki stream, not a separate synthetic
   one, distinguished by the event="deploy" logfmt field already required
   regardless (OBS-038's dashboard always filters on it). workspace/domain/
   primitive/release are promoted to real stream labels the same way Alloy
   promotes them for application pod logs (platform/shared/observability/alloy/
   logs.alloy.tftpl's observability_taxonomy_labels) -- deliberately
   excluding env, matching that same set. *)
(* obs-loki-eio 0.2 exports asynchronously (OBS-048), so the event is flushed
   before this returns -- the CLI exits right after. A failed push is reported
   on stderr by the exporter ("[obs-loki] push failed ..."); it never fails the
   deploy. *)
let push_event ~sw ~net ~clock ~mono_clock ~url (event : Sol_cli_deploy_event.t) =
  try
    let loki =
      Obs_loki.create ~sw ~net ~clock ~url ~label_names:deploy_event_stream_labels ()
    in
    let ot =
      Obs_eio.create
        ~service:event.service
        ~mono_clock
        ~backend:(Obs_loki.backend loki)
        ()
    in
    let ot =
      Obs_eio.with_context
        ot
        [ "workspace", event.workspace
        ; "domain", event.domain
        ; "primitive", event.primitive
        ; "release", Sol_cli_release_id.to_string event.release_id
        ]
    in
    Obs_eio.log_standalone
      ot
      Obs_eio.Info
      ~fields:(Sol_cli_deploy_event.fields event)
      (Sol_cli_deploy_event.message event);
    Obs_loki.flush loki
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn ->
    Printf.eprintf
      "warning: could not push deploy event to Loki: %s\n%!"
      (Printexc.to_string exn)
;;

(* Top-level entry point for cmd_deploy.ml. Resolves the push URL once,
   then pushes one event per deployed service over a single Eio_main.run --
   scoped to just this call, like cmd_migrate.ml's with_pool, rather than
   wrapping the whole sol binary in Eio. A no-op (no Eio_main.run at all)
   when there is nothing to push to, or no events. *)
let push_all ~ctx ~backend ~explicit_url (events : Sol_cli_deploy_event.t list) =
  if events <> []
  then
    resolve_url ~ctx ~backend ~explicit_url
    |> Option.iter (fun url ->
      Eio_main.run (fun env ->
        Eio.Switch.run
        @@ fun sw ->
        List.iter
          (push_event ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~url)
          events))
;;
