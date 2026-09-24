module type HANDLER = sig
  val routes : Route.t list
end

(* ── Routing ───────────────────────────────────────────────────────────── *)

type route_match =
  | Found of Route.t * (string * string) list
  | Method_not_allowed
  | Not_found

let find_route routes meth path =
  let path_matched = ref false in
  let rec loop = function
    | [] -> if !path_matched then Method_not_allowed else Not_found
    | r :: rest ->
      (match Route_internal.match_path r.Route.pattern path with
       | None -> loop rest
       | Some params ->
         path_matched := true;
         if r.Route.method_ = meth then Found (r, params) else loop rest)
  in
  loop routes
;;

(* ── HTTP status conversion ────────────────────────────────────────────── *)

let http_status_of_int = function
  | 200 -> `OK
  | 201 -> `Created
  | 204 -> `No_content
  | 400 -> `Bad_request
  | 401 -> `Unauthorized
  | 403 -> `Forbidden
  | 404 -> `Not_found
  | 405 -> `Method_not_allowed
  | 413 -> `Request_entity_too_large
  | 422 -> `Unprocessable_entity
  | 500 -> `Internal_server_error
  | 501 -> `Not_implemented
  | n -> `Code n
;;

(* ── Body reading ──────────────────────────────────────────────────────── *)

let read_body_limited headers (body : Cohttp_eio.Body.t) max_bytes =
  let too_large_from_header =
    match Http.Header.get headers "content-length" with
    | None -> false
    | Some s ->
      (try int_of_string (String.trim s) > max_bytes with
       | _ -> false)
  in
  if too_large_from_header
  then None
  else (
    match
      let buf = Eio.Buf_read.of_flow body ~max_size:max_bytes in
      Eio.Buf_read.take_all buf
    with
    | exception Eio.Buf_read.Buffer_limit_exceeded -> None
    | s -> Some s)
;;

(* ── Dispatch ──────────────────────────────────────────────────────────── *)

let ( let* ) = Result.bind

let auth_result ?read_api_key ?fetch_jwks auth_cfg headers =
  match Auth_internal.validate ?read_api_key ?fetch_jwks auth_cfg headers with
  | Error (`Unauthorized _) -> Error Response.unauthorized
  | Error (`Forbidden _) -> Error Response.forbidden
  | Error (`Server_error msg) -> Error (Response.internal_error msg)
  | Ok ctx -> Ok ctx
;;

let body_result headers body max_bytes =
  match read_body_limited headers body max_bytes with
  | None -> Error Response.payload_too_large
  | Some s -> Ok s
;;

let dispatch_unguarded
      ?read_api_key
      ?fetch_jwks
      ~routes
      ~metrics_renderer
      ~metrics_auth
      ~max_body_bytes
      ?route_observer
      ?(ready = fun () -> true)
      req
      body
  =
  let meth_opt = Route_internal.method_of_http (Http.Request.meth req) in
  match meth_opt with
  | None -> { Response.status = 405; headers = []; body = "" }
  | Some meth ->
    let resource = Http.Request.resource req in
    let uri = Uri.of_string resource in
    let path = Uri.path uri in
    let headers = Http.Request.headers req in
    if Route.parse_request_path path = None
    then { Response.status = 400; headers = []; body = "Bad Request" }
    else (
      let observe lbl =
        match route_observer with
        | Some f -> f lbl
        | None -> ()
      in
      let builtin =
        match meth, path with
        | `GET, "/healthz" ->
          observe "/healthz";
          Some (Response.json {|{"status":"ok"}|})
        (* INFRA-073 / FND-0041(c): readiness, distinct from liveness. It turns 503
           as soon as shutdown begins, while the listener keeps serving for
           [shutdown_delay_s], so Kubernetes removes the endpoint before the pod
           stops accepting instead of refusing requests routed to it. *)
        | `GET, "/readyz" ->
          observe "/readyz";
          Some
            (if ready ()
             then Response.json {|{"status":"ready"}|}
             else
               { Response.status = 503
               ; headers = [ "content-type", "application/json" ]
               ; body = {|{"status":"shutting down"}|}
               })
        | `GET, "/metrics" ->
          observe "/metrics";
          (match metrics_renderer with
           | None -> Some Response.not_found
           | Some render ->
             let result =
               let* _ = auth_result ?read_api_key ?fetch_jwks metrics_auth headers in
               Ok
                 (Response.ok
                    ~headers:
                      [ "content-type", "text/plain; version=0.0.4; charset=utf-8" ]
                    (render ()))
             in
             Some
               (match result with
                | Ok r | Error r -> r))
        | _ -> None
      in
      match builtin with
      | Some r -> r
      | None ->
        (match find_route routes meth path with
         | Not_found ->
           observe "unmatched";
           Response.not_found
         | Method_not_allowed ->
           observe "unmatched";
           { Response.status = 405; headers = []; body = "" }
         | Found (route, params) ->
           observe (Route.pattern_to_string route.Route.pattern);
           let result =
             let* auth_ctx =
               auth_result ?read_api_key ?fetch_jwks route.Route.auth headers
             in
             let* body_str = body_result headers body max_body_bytes in
             let trace_ctx =
               Http.Header.to_list headers |> Obs_trace.extract_from_headers
             in
             let sol_req =
               Request.
                 { method_ = meth
                 ; path
                 ; headers
                 ; params
                 ; uri
                 ; body = body_str
                 ; auth = auth_ctx
                 ; trace_ctx
                 }
             in
             try Ok (route.Route.handler sol_req) with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
             | exn ->
               Printf.eprintf
                 "sol-svc: handler exception: %s\n%!"
                 (Printexc.to_string exn);
               Ok (Response.internal_error "Internal server error")
           in
           (match result with
            | Ok r | Error r -> r)))
;;

(* BUG-053 / FND-0050: every request gets a response. The handler has its own
   boundary above, but authentication and body reading ran outside it, so an
   exception there escaped into cohttp-eio, which closes the connection without
   a response -- and the request was never counted. *)
let respond_or_500 f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn ->
    Printf.eprintf "sol-svc: request failed: %s\n%!" (Printexc.to_string exn);
    Response.internal_error "Internal server error"
;;

let dispatch
      ?read_api_key
      ?fetch_jwks
      ~routes
      ~metrics_renderer
      ~metrics_auth
      ~max_body_bytes
      ?route_observer
      ~ready
      req
      body
  =
  respond_or_500 (fun () ->
    dispatch_unguarded
      ?read_api_key
      ?fetch_jwks
      ~routes
      ~metrics_renderer
      ~metrics_auth
      ~max_body_bytes
      ?route_observer
      ~ready
      req
      body)
;;

module For_testing = struct
  let respond_or_500 = respond_or_500

  let dispatch ?fetch_jwks ~routes req body =
    dispatch
      ?fetch_jwks
      ~routes
      ~metrics_renderer:None
      ~metrics_auth:`Public
      ~max_body_bytes:1_048_576
      ~ready:(fun () -> true)
      req
      body
  ;;
end

(* ── Make functor ──────────────────────────────────────────────────────── *)

exception Drain_timeout

type run_error = [ `Config of string ]

let run_error_to_string (`Config msg) = "sol-svc: config error: " ^ msg

let auth_uses_api_key = function
  | `Api_key -> true
  | `Public | `Jwt _ -> false
;;

let api_key_required routes metrics_auth =
  auth_uses_api_key metrics_auth
  || List.exists (fun route -> auth_uses_api_key route.Route.auth) routes
;;

(* SEC-006 / FND-0037: [Unverified_dev_only] trusts any token without checking its
   signature. Its name was the only thing keeping it off a real route, so a service
   that uses it refuses to start unless the environment opts in explicitly.
   [sol up] renders the opt-in for the local cluster only; [sol deploy] never does. *)
let unverified_jwt_opt_in = "SOL_ALLOW_UNVERIFIED_JWT"

let auth_is_unverified_jwt = function
  | `Jwt { Auth.verification = Auth.Unverified_dev_only; _ } -> true
  | `Jwt { Auth.verification = Auth.Verified_signature_required _; _ }
  | `Public | `Api_key -> false
;;

let refuse_unverified_jwt routes metrics_auth =
  let used =
    auth_is_unverified_jwt metrics_auth
    || List.exists (fun route -> auth_is_unverified_jwt route.Route.auth) routes
  in
  if used && Sys.getenv_opt unverified_jwt_opt_in <> Some "1"
  then
    Error
      (`Config
          (Printf.sprintf
             "a route uses Unverified_dev_only JWT auth, which accepts tokens without \
              checking their signature. It runs only where %s=1 (sol up sets this on the \
              local cluster). Use Verified_signature_required."
             unverified_jwt_opt_in))
  else Ok ()
;;

(* SEC-009 / FND-0053: [Jwks_url] is documented as fetched over TLS, but the
   HTTP client falls back to plain HTTP for any other scheme, and the keys it
   returns are trusted to verify signatures. An http:// JWKS lets anyone on the
   path substitute them, so it is a startup error, not a runtime surprise. *)
let jwks_url_of = function
  | `Jwt { Auth.verification = Auth.Verified_signature_required { key_source; _ }; _ } ->
    (match key_source with
     | Auth.Jwks_url url -> Some url
     | Auth.Jwks_static _ | Auth.Hs256_secret _ -> None)
  | `Jwt { Auth.verification = Auth.Unverified_dev_only; _ } | `Public | `Api_key -> None
;;

let refuse_non_https_jwks routes metrics_auth =
  let is_https url =
    let uri = Uri.of_string url in
    match Uri.scheme uri, Uri.host uri with
    | Some scheme, Some host -> String.lowercase_ascii scheme = "https" && host <> ""
    | _ -> false
  in
  match
    List.find_map
      (fun auth ->
         match jwks_url_of auth with
         | Some url when not (is_https url) -> Some url
         | _ -> None)
      (metrics_auth :: List.map (fun route -> route.Route.auth) routes)
  with
  | None -> Ok ()
  | Some url ->
    Error
      (`Config
          (Printf.sprintf
             "Jwks_url must be an absolute https:// URL (the keys verify token \
              signatures, so they must not travel in plaintext): %S"
             url))
;;

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None
;;

let api_key_reader ~env ~required =
  match env_nonempty "SOL_API_KEY_FILE", env_nonempty "SOL_API_KEY" with
  | Some path, _ ->
    (try
       let key = String.trim (Eio.Path.load Eio.Path.(env#fs / path)) in
       if key = ""
       then Error (`Config ("API key file is empty: " ^ path))
       else Ok (fun () -> Some key)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
     | exn ->
       Error
         (`Config
             ("could not read SOL_API_KEY_FILE " ^ path ^ ": " ^ Printexc.to_string exn)))
  | None, Some key when String.trim key <> "" ->
    let key = String.trim key in
    Ok (fun () -> Some key)
  | None, _ when required ->
    Error (`Config "API key auth configured but SOL_API_KEY/SOL_API_KEY_FILE is not set")
  | None, _ -> Ok (fun () -> None)
;;

module Make (H : HANDLER) = struct
  let run
        ~(env :
           < net : _ Eio.Net.t
           ; clock : _ Eio.Time.clock
           ; fs : Eio.Fs.dir_ty Eio.Path.t
           ; .. >)
        ?(port = 8080)
        ?(metrics_auth = `Public)
        ?ot
        ?(max_body_bytes = 10_485_760)
        ?(drain_timeout_s = 30.0)
        ?(shutdown_delay_s = 5.0)
        ?stop
        ?on_listen
        ()
    =
    (* BUG-046: a PORT that is set but is not a port number is a configuration
       error. Falling back to the default made the service listen somewhere the
       Service and its probes do not point, with nothing naming the bad value. *)
    let* port =
      (* Set-but-empty is treated as unset, like every other variable here. *)
      match env_nonempty "PORT" with
      | None -> Ok port
      | Some raw ->
        (match int_of_string_opt (String.trim raw) with
         | Some p when p >= 0 && p <= 65535 -> Ok p
         | _ ->
           Error (`Config (Printf.sprintf "PORT=%S is not a port number (0-65535)" raw)))
    in
    let ot_eio = Option.map Sol_obs.obs_eio ot in
    let metrics_renderer = Option.map Sol_obs.metrics_renderer ot in
    (* Register per-request metrics once at startup, reuse emitters per request *)
    let metrics_fns =
      match ot_eio with
      | None -> None
      | Some o ->
        let req_count, req_duration =
          Obs_eio.register_counter_and_histogram
            o
            ~counter_name:"sol_svc_requests_total"
            ~counter_help:"Total HTTP requests by method, route, and HTTP status class"
            ~counter_labels:[ "method"; "route"; "status_class" ]
            ~histogram_name:"sol_svc_request_duration_seconds"
            ~histogram_help:"HTTP request latency in seconds by method and route"
            ~histogram_labels:[ "method"; "route" ]
        in
        Some (req_count, req_duration)
    in
    let fetch_jwks = Auth_internal.fetch_jwks_over_https ~env in
    let* () = refuse_unverified_jwt H.routes metrics_auth in
    let* () = refuse_non_https_jwks H.routes metrics_auth in
    let* read_api_key =
      api_key_reader ~env ~required:(api_key_required H.routes metrics_auth)
    in
    let ready = Atomic.make true in
    let signal_stop, signal_stop_r = Eio.Promise.create () in
    let await_stop () =
      match stop with
      | None -> Eio.Promise.await signal_stop
      | Some external_stop ->
        Eio.Fiber.first
          (fun () -> Eio.Promise.await signal_stop)
          (fun () -> Eio.Promise.await external_stop)
    in
    (try
       Eio.Switch.run (fun sw ->
         Sol_runtime.install_signal_handler ~sw signal_stop_r;
         let socket =
           Eio.Net.listen
             ~sw
             ~reuse_addr:true
             ~backlog:128
             env#net
             (`Tcp (Eio.Net.Ipaddr.V4.any, port))
         in
         let actual_port =
           match Eio.Net.listening_addr socket with
           | `Tcp (_, p) -> p
           | _ -> port
         in
         (match on_listen with
          | Some f -> f actual_port
          | None -> ());
         Printf.eprintf "sol-svc listening on :%d\n%!" actual_port;
         let callback _conn req body =
           let t0 =
             match metrics_fns with
             | Some _ -> Some (Eio.Time.now env#clock)
             | None -> None
           in
           let route_ref = ref "unmatched" in
           let route_observer =
             match metrics_fns with
             | None -> None
             | Some _ -> Some (fun lbl -> route_ref := lbl)
           in
           let sol_resp =
             dispatch
               ~fetch_jwks
               ~routes:H.routes
               ~metrics_renderer
               ~metrics_auth
               ~read_api_key
               ~max_body_bytes
               ?route_observer
               ~ready:(fun () -> Atomic.get ready)
               req
               body
           in
           (match metrics_fns, t0 with
            | Some (req_count, req_duration), Some t0 ->
              let dt = Eio.Time.now env#clock -. t0 in
              let meth_str =
                match Http.Request.meth req with
                | `GET -> "GET"
                | `POST -> "POST"
                | `PUT -> "PUT"
                | `PATCH -> "PATCH"
                | `DELETE -> "DELETE"
                | _ -> "OTHER"
              in
              let route = !route_ref in
              let sc = string_of_int (sol_resp.Response.status / 100) ^ "xx" in
              req_count
                ~labels:[ "method", meth_str; "route", route; "status_class", sc ]
                1;
              req_duration ~labels:[ "method", meth_str; "route", route ] dt
            | _ -> ());
           let body_str = sol_resp.Response.body in
           let headers =
             Http.Header.of_list
               (("content-length", string_of_int (String.length body_str))
                :: sol_resp.Response.headers)
           in
           Cohttp_eio.Server.respond
             ~status:(http_status_of_int sol_resp.Response.status)
             ~headers
             ~body:(Cohttp_eio.Body.of_string body_str)
             ()
         in
         let server = Cohttp_eio.Server.make ~callback () in
         (* BUG-046: the server stops accepting on a signal *or* on the caller's
              [stop]. It used to watch only the signal, so an external stop kept it
              accepting for the whole drain window and then reported a drain
              timeout even with nothing in flight. *)
         let server_stop, server_stop_r = Eio.Promise.create () in
         (* INFRA-073: on stop, readiness goes 503 first; the listener keeps
              serving for [shutdown_delay_s] so endpoint removal can propagate,
              then stops accepting and drains. *)
         Eio.Fiber.fork_daemon ~sw (fun () ->
           await_stop ();
           Atomic.set ready false;
           if shutdown_delay_s > 0.0 then Eio.Time.sleep env#clock shutdown_delay_s;
           ignore (Eio.Promise.try_resolve server_stop_r ());
           `Stop_daemon);
         (* Race: serve exits naturally when connections drain, or drain guard fires
         after drain_timeout_s and raises Drain_timeout to force cancellation. *)
         Eio.Fiber.first
           (fun () ->
              Cohttp_eio.Server.run
                ~stop:server_stop
                ~on_error:(fun e ->
                  Printf.eprintf "sol-svc: %s\n%!" (Printexc.to_string e))
                socket
                server)
           (fun () ->
              await_stop ();
              Eio.Time.sleep env#clock (shutdown_delay_s +. drain_timeout_s);
              raise Drain_timeout))
     with
     | Drain_timeout ->
       Printf.eprintf "sol-svc: drain timeout reached, forcing shutdown\n%!");
    (* OBS-048: flush the asynchronous Loki/Tempo export on the way out, drained
       or not. *)
    Option.iter (fun o -> Sol_obs.flush o) ot;
    Ok ()
  ;;
end

let run routes =
  let module H = struct
    let routes = routes
  end
  in
  let module S = Make (H) in
  S.run
;;
