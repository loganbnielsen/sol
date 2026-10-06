let loki_local_port = 13100
let loki_remote_port = Sol_cli_manifest.loki_service_port
let loki_namespace = Sol_cli_manifest.monitoring_namespace
let loki_service = Sol_cli_manifest.loki_service

let cluster_loki_exists ~ctx () =
  Result.is_ok
    (Sol_cli_kubectl.get
       ~ctx
       ~resource:"svc"
       ~name:loki_service
       ~namespace:loki_namespace
       ~output:"name")
;;

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

let deploy_event_stream_labels =
  [ Obs_loki.stream_label_exn "workspace"
  ; Obs_loki.stream_label_exn "domain"
  ; Obs_loki.stream_label_exn "primitive"
  ; Obs_loki.stream_label_exn "release"
  ]
;;

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
