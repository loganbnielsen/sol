(* sol deploy's release-event push to Loki (OBS-037). Kept out of
   cmd_deploy.ml since it's the only place in cli/sol/bin that needs
   obs-eio/obs-loki-eio -- cmd_migrate.ml is the only other module that
   scopes an Eio_main.run to a single command's I/O rather than wrapping
   the whole binary, and this follows the same pattern. *)

let loki_local_port = 13100
let loki_remote_port = 3100
let loki_namespace = "monitoring"
let loki_service = "loki"

(* Mirrors cmd_migrate.ml's cluster_pg_exists -- a live kubectl probe, not a
   guess, since sol deploy's direct-apply mode already has cluster access. *)
let cluster_loki_exists () =
  match
    Sol_cli_kubectl.get ~resource:"svc" ~name:loki_service
      ~namespace:loki_namespace ~output:"name"
  with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false

(* Mirrors cmd_migrate.ml's auto_forward_pg: spawn a temporary kubectl
   port-forward, poll until it accepts a TCP connection, register at_exit
   cleanup. sol deploy exits shortly after this call either way (this runs
   from the tail of a real, non-dry-run, non-emit-to apply), so at_exit
   teardown is sufficient -- same precedent, not a new one. Returns the
   local push URL, or [None] if the forward never started or never became
   ready in time (never raises; a failed forward here must not fail the
   deploy). *)
let auto_forward_loki () =
  Printf.eprintf "Forwarding loki (cluster) -> localhost:%d ...\n%!"
    loki_local_port;
  let devnull_w = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  match
    Unix.create_process "kubectl"
      [|
        "kubectl";
        "port-forward";
        Printf.sprintf "svc/%s" loki_service;
        "-n";
        loki_namespace;
        Printf.sprintf "%d:%d" loki_local_port loki_remote_port;
      |]
      Unix.stdin devnull_w devnull_w
  with
  | exception Unix.Unix_error (e, fn, _) ->
      Unix.close devnull_w;
      Printf.eprintf
        "warning: could not start kubectl port-forward for loki: %s: %s\n%!" fn
        (Unix.error_message e);
      None
  | pid ->
      Unix.close devnull_w;
      at_exit (fun () ->
          (try Unix.kill pid Sys.sigterm with _ -> ());
          try ignore (Unix.waitpid [ Unix.WNOHANG ] pid) with _ -> ());
      let is_not_listening_yet = function
        | Unix.ECONNREFUSED | Unix.ETIMEDOUT | Unix.ENETUNREACH
        | Unix.EHOSTUNREACH | Unix.ECONNRESET ->
            true
        | _ -> false
      in
      let check_connect () =
        match Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 with
        | exception Unix.Unix_error (e, fn, _) ->
            `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
        | s -> (
            let addr =
              Unix.ADDR_INET (Unix.inet_addr_loopback, loki_local_port)
            in
            match Unix.connect s addr with
            | () ->
                Unix.close s;
                `Ready
            | exception Unix.Unix_error (e, _, _) when is_not_listening_yet e ->
                Unix.close s;
                `Not_listening_yet
            | exception Unix.Unix_error (e, fn, _) ->
                Unix.close s;
                `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
            | exception exn ->
                Unix.close s;
                `Failed (Printexc.to_string exn))
      in
      let rec wait n =
        if n = 0 then begin
          Printf.eprintf
            "warning: loki port-forward did not become ready in time\n%!";
          false
        end
        else
          match check_connect () with
          | `Ready -> true
          | `Not_listening_yet ->
              Unix.sleepf 0.5;
              wait (n - 1)
          | `Failed msg ->
              Printf.eprintf
                "warning: loki port-forward readiness check failed: %s\n%!" msg;
              false
      in
      if wait 10 then
        Some (Printf.sprintf "http://localhost:%d" loki_local_port)
      else None

(* Resolves Sol_cli_deploy_event.resolve_push_url's decision into an actual
   URL, performing the I/O (kubectl probe + port-forward) that decision
   layer deliberately leaves to its caller. Never raises; prints an
   explanatory note/warning and returns [None] for every "nothing to push
   to" outcome. *)
let resolve_url ~backend ~explicit_url =
  match Sol_cli_deploy_event.resolve_push_url ~backend ~explicit_url with
  | Sol_cli_deploy_event.Explicit url -> Some url
  | Sol_cli_deploy_event.Auto_detect ->
      if cluster_loki_exists () then auto_forward_loki ()
      else begin
        Printf.eprintf
          "note: no in-cluster Loki service found (svc/%s -n %s); skipping \
           deploy-event log push. Pass --loki-push-url to record this deploy's \
           release event anyway.\n\
           %!"
          loki_service loki_namespace;
        None
      end
  | Sol_cli_deploy_event.Skip reason ->
      Printf.eprintf "note: %s\n%!" reason;
      None

(* Push one event. Failure to push must never fail the deploy (OBS-037) --
   Obs_eio already routes ordinary backend exceptions raised while closing
   the span to its own on_backend_error hook (default: print to stderr,
   don't propagate), so this try/with is a second, redundant safety net
   over synchronous failures outside that path (e.g. Obs_loki.create
   rejecting a malformed --loki-push-url). Cancellation and fatal runtime
   exceptions are deliberately re-raised, not swallowed -- same exclusion
   list Obs_eio.report_backend_error itself uses. *)
let deploy_event_stream_labels =
  [
    Obs_loki.stream_label_exn "workspace";
    Obs_loki.stream_label_exn "domain";
    Obs_loki.stream_label_exn "primitive";
    Obs_loki.stream_label_exn "release";
  ]

(* [service] is the deployed service's real name (Obs_eio.create's built-in
   stream label), matching every real app pod's own convention -- deploy
   events land in that service's own Loki stream, not a separate synthetic
   one, distinguished by the event="deploy" logfmt field already required
   regardless (OBS-038's dashboard always filters on it). workspace/domain/
   primitive/release are promoted to real stream labels the same way Alloy
   promotes them for application pod logs (cli/platform/infra/base/alloy/
   logs.alloy.tftpl's observability_taxonomy_labels) -- deliberately
   excluding env, matching that same set. *)
let push_event ~net ~clock ~mono_clock ~url (event : Sol_cli_deploy_event.t) =
  try
    let backend =
      Obs_loki.create ~net ~clock ~url ~label_names:deploy_event_stream_labels
        ()
    in
    let ot =
      Obs_eio.create ~service:event.Sol_cli_deploy_event.service ~mono_clock
        ~backend ()
    in
    let ot =
      Obs_eio.with_context ot
        [
          ("workspace", event.Sol_cli_deploy_event.workspace);
          ("domain", event.Sol_cli_deploy_event.domain);
          ("primitive", event.Sol_cli_deploy_event.primitive);
          ("release", event.Sol_cli_deploy_event.release);
        ]
    in
    Obs_eio.log_standalone ot Obs_eio.Info
      ~fields:(Sol_cli_deploy_event.fields event)
      (Sol_cli_deploy_event.message event)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn ->
      Printf.eprintf "warning: could not push deploy event to Loki: %s\n%!"
        (Printexc.to_string exn)

(* Top-level entry point for cmd_deploy.ml. Resolves the push URL once,
   then pushes one event per deployed service over a single Eio_main.run --
   scoped to just this call, like cmd_migrate.ml's with_pool, rather than
   wrapping the whole sol binary in Eio. A no-op (no Eio_main.run at all)
   when there is nothing to push to, or no events. *)
let push_all ~backend ~explicit_url (events : Sol_cli_deploy_event.t list) =
  if events <> [] then
    match resolve_url ~backend ~explicit_url with
    | None -> ()
    | Some url ->
        Eio_main.run (fun env ->
            List.iter
              (push_event ~net:env#net ~clock:env#clock
                 ~mono_clock:env#mono_clock ~url)
              events)
