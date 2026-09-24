open Eio.Std

let contains needle s =
  let nl = String.length needle
  and sl = String.length s in
  if nl > sl
  then false
  else (
    let found = ref false in
    for i = 0 to sl - nl do
      if not !found
      then (
        let rec eq j =
          j >= nl
          || (String.unsafe_get s (i + j) = String.unsafe_get needle j && eq (j + 1))
        in
        if eq 0 then found := true)
    done;
    !found)
;;

(* ── Test handler fixtures ───────────────────────────────────────────── *)

let get_json _req = Response.json {|{"ok":true}|}
let echo_body req = Response.ok req.Request.body
let jwt_cfg scopes = `Jwt Auth.{ scopes; verification = Unverified_dev_only }

let make_jwt ?(scopes = [ "read" ]) () =
  let header =
    Base64.encode_exn
      ~pad:false
      ~alphabet:Base64.uri_safe_alphabet
      {|{"alg":"HS256","typ":"JWT"}|}
  in
  let now = Unix.gettimeofday () in
  let exp = int_of_float (now +. 3600.0) in
  let scope = String.concat " " scopes in
  let payload = Printf.sprintf {|{"sub":"u1","scope":"%s","exp":%d}|} scope exp in
  let b64 = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet payload in
  header ^ "." ^ b64 ^ ".sig"
;;

module H = struct
  let routes =
    [ Route.get "/hello" ~auth:`Public get_json
    ; Route.post "/echo" ~auth:`Public echo_body
    ; Route.get "/protected" ~auth:(jwt_cfg [ "read" ]) get_json
    ; Route.get "/users/:id" ~auth:`Public (fun req ->
        Response.json (Printf.sprintf {|{"id":"%s"}|} (Request.param_exn req "id")))
    ]
  ;;
end

(* ── Test server helpers ─────────────────────────────────────────────── *)

let with_server env ~sw f =
  let port_p, port_r = Promise.create () in
  let stop, stop_r = Promise.create () in
  Fiber.fork ~sw (fun () ->
    let module S = Service.Make (H) in
    S.run
      ~env
      ~port:0
      ~stop
      ~shutdown_delay_s:0.0
      ~drain_timeout_s:0.1
      ~on_listen:(fun p -> Promise.resolve port_r p)
      ()
    |> Result.map_error Service.run_error_to_string
    |> function
    | Ok () -> ()
    | Error e -> failwith e);
  let port = Promise.await port_p in
  Fun.protect
    (fun () -> f port)
    ~finally:(fun () ->
      try Promise.resolve stop_r () with
      | _ -> ())
;;

let with_server_obs env ~sw f =
  let port_p, port_r = Promise.create () in
  let stop, stop_r = Promise.create () in
  let obs =
    Sol_obs.of_env
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"test-svc"
      ()
  in
  Fiber.fork ~sw (fun () ->
    let module S = Service.Make (H) in
    S.run
      ~env
      ~port:0
      ~ot:obs
      ~stop
      ~shutdown_delay_s:0.0
      ~drain_timeout_s:0.1
      ~on_listen:(fun p -> Promise.resolve port_r p)
      ()
    |> Result.map_error Service.run_error_to_string
    |> function
    | Ok () -> ()
    | Error e -> failwith e);
  let port = Promise.await port_p in
  Fun.protect
    (fun () -> f port (Sol_obs.metrics_renderer obs))
    ~finally:(fun () ->
      try Promise.resolve stop_r () with
      | _ -> ())
;;

(* Make an HTTP request and return (status_code, body_string). *)
let http_call env ~sw ~port ~meth ~path ?(headers = []) ?(body = "") () =
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path) in
  let hdrs = Http.Header.of_list (("connection", "close") :: headers) in
  let body_val = if body = "" then None else Some (Cohttp_eio.Body.of_string body) in
  let resp, resp_body =
    Cohttp_eio.Client.call client ~sw ~headers:hdrs ?body:body_val meth uri
  in
  let status = Http.Status.to_int (Http.Response.status resp) in
  let body_str = Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:65536 in
  status, body_str
;;

(* ── Tests ───────────────────────────────────────────────────────────── *)

let test_healthz env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, body = http_call env ~sw ~port ~meth:`GET ~path:"/healthz" () in
      Alcotest.(check int) "status 200" 200 status;
      Alcotest.(check bool) "body ok" true (String.trim body = {|{"status":"ok"}|})))
;;

let test_not_found env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/does-not-exist" () in
      Alcotest.(check int) "status 404" 404 status))
;;

let test_method_not_allowed env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      (* /hello is GET only *)
      let status, _ = http_call env ~sw ~port ~meth:`DELETE ~path:"/hello" () in
      Alcotest.(check int) "status 405" 405 status))
;;

let test_public_route env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/hello" () in
      Alcotest.(check int) "status 200" 200 status))
;;

let test_path_param env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, body = http_call env ~sw ~port ~meth:`GET ~path:"/users/42" () in
      Alcotest.(check int) "status 200" 200 status;
      Alcotest.(check bool)
        "contains id"
        true
        (try
           let _ = String.index body '4' in
           true
         with
         | Not_found -> false)))
;;

let test_echo_body env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, body =
        http_call env ~sw ~port ~meth:`POST ~path:"/echo" ~body:"hello world" ()
      in
      Alcotest.(check int) "status 200" 200 status;
      Alcotest.(check bool) "body echoed" true (String.trim body = "hello world")))
;;

let test_jwt_no_token env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/protected" () in
      Alcotest.(check int) "status 401" 401 status))
;;

let test_jwt_valid_token env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let tok = make_jwt ~scopes:[ "read" ] () in
      let status, _ =
        http_call
          env
          ~sw
          ~port
          ~meth:`GET
          ~path:"/protected"
          ~headers:[ "authorization", "Bearer " ^ tok ]
          ()
      in
      Alcotest.(check int) "status 200" 200 status))
;;

let test_jwt_missing_scope env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let tok = make_jwt ~scopes:[ "other" ] () in
      let status, _ =
        http_call
          env
          ~sw
          ~port
          ~meth:`GET
          ~path:"/protected"
          ~headers:[ "authorization", "Bearer " ^ tok ]
          ()
      in
      Alcotest.(check int) "status 403" 403 status))
;;

let test_metrics_no_renderer env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/metrics" () in
      Alcotest.(check int) "status 404" 404 status))
;;

let test_handler_exception env () =
  let module Hx = struct
    let routes =
      [ Route.get "/boom" ~auth:`Public (fun _ -> raise (Failure "boom"))
      ; Route.get "/ok" ~auth:`Public (fun _ -> Response.json {|"ok"|})
      ]
    ;;
  end
  in
  let port_p, port_r = Promise.create () in
  let stop, stop_r = Promise.create () in
  Switch.run (fun sw ->
    Fiber.fork ~sw (fun () ->
      let module S = Service.Make (Hx) in
      S.run
        ~env
        ~port:0
        ~stop
        ~shutdown_delay_s:0.0
        ~drain_timeout_s:0.1
        ~on_listen:(fun p -> Promise.resolve port_r p)
        ()
      |> Result.map_error Service.run_error_to_string
      |> function
      | Ok () -> ()
      | Error e -> failwith e);
    let port = Promise.await port_p in
    let s1, _ = http_call env ~sw ~port ~meth:`GET ~path:"/boom" () in
    Alcotest.(check int) "500 on exception" 500 s1;
    let s2, _ = http_call env ~sw ~port ~meth:`GET ~path:"/ok" () in
    Alcotest.(check int) "server still up" 200 s2;
    Promise.resolve stop_r ())
;;

let test_external_stop_on_listen env () =
  Switch.run (fun _sw ->
    let module S = Service.Make (H) in
    let stop, stop_r = Promise.create () in
    match
      S.run
        ~env
        ~port:0
        ~stop
        ~shutdown_delay_s:0.0
        ~drain_timeout_s:0.1
        ~on_listen:(fun _ -> Promise.resolve stop_r ())
        ()
    with
    | Ok () -> ()
    | Error e -> Alcotest.fail (Service.run_error_to_string e))
;;

let test_metrics_counter env () =
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _ = http_call env ~sw ~port ~meth:`GET ~path:"/hello" () in
      let output = render () in
      Alcotest.(check bool)
        "requests_total counter present"
        true
        (contains "sol_svc_requests_total" output);
      Alcotest.(check bool)
        "route label in output"
        true
        (contains {|route="/hello"|} output);
      Alcotest.(check bool)
        "status_class label in output"
        true
        (contains {|status_class="2xx"|} output)))
;;

let test_metrics_duration env () =
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _ = http_call env ~sw ~port ~meth:`GET ~path:"/hello" () in
      let output = render () in
      Alcotest.(check bool)
        "duration histogram present"
        true
        (contains "sol_svc_request_duration_seconds" output)))
;;

let test_metrics_route_pattern_label env () =
  (* Route label must use the pattern ("/users/:id"), not the actual path
     value ("/users/42"), so label cardinality stays bounded. *)
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _ = http_call env ~sw ~port ~meth:`GET ~path:"/users/42" () in
      let _ = http_call env ~sw ~port ~meth:`GET ~path:"/users/999" () in
      let output = render () in
      Alcotest.(check bool)
        "pattern label present"
        true
        (contains {|route="/users/:id"|} output);
      Alcotest.(check bool)
        "concrete value 42 not a label"
        false
        (contains {|route="/users/42"|} output);
      Alcotest.(check bool)
        "concrete value 999 not a label"
        false
        (contains {|route="/users/999"|} output)))
;;

(* ── Auth-before-body-read tests ────────────────────────────────────────── *)

module Hauth = struct
  let routes =
    [ Route.post "/upload" ~auth:`Public echo_body
    ; Route.post "/protected-upload" ~auth:(jwt_cfg [ "write" ]) echo_body
    ]
  ;;
end

module Hapi_key = struct
  let routes = [ Route.get "/api-key" ~auth:`Api_key get_json ]
end

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () -> Unix.putenv name (Option.value old ~default:""))
;;

let test_api_key_file_error_is_startup_error env () =
  with_env "SOL_API_KEY" "" (fun () ->
    with_env "SOL_API_KEY_FILE" "/definitely/not/a/sol/api/key" (fun () ->
      let module S = Service.Make (Hapi_key) in
      match S.run ~env ~port:0 () with
      | Error (`Config msg) ->
        Alcotest.(check bool)
          "mentions API key file"
          true
          (contains "SOL_API_KEY_FILE" msg)
      | Ok () -> Alcotest.fail "expected API key file config error"))
;;

(* SEC-006: a service using Unverified_dev_only refuses to start unless the
   environment opts in. The test binary opts in globally (it is a development
   environment); these cases take the opt-in away. *)
module Hunverified = struct
  let routes = [ Route.get "/jwt" ~auth:(jwt_cfg [ "read" ]) get_json ]
end

let expect_unverified_refused result =
  match result with
  | Error (`Config msg) ->
    Alcotest.(check bool)
      "names the opt-in"
      true
      (contains "SOL_ALLOW_UNVERIFIED_JWT" msg)
  | Ok () -> Alcotest.fail "expected Unverified_dev_only to be refused without the opt-in"
;;

(* An already-resolved [stop] and a short drain make a missing guard return
   [Ok ()] promptly instead of serving forever, so the test fails, not hangs. *)
let stopped () =
  let p, r = Promise.create () in
  Promise.resolve r ();
  p
;;

let test_unverified_jwt_refused_without_opt_in env () =
  with_env "SOL_ALLOW_UNVERIFIED_JWT" "" (fun () ->
    let module S = Service.Make (Hunverified) in
    expect_unverified_refused
      (S.run ~env ~port:0 ~stop:(stopped ()) ~drain_timeout_s:0.1 ()))
;;

let test_unverified_metrics_auth_refused_without_opt_in env () =
  with_env "SOL_ALLOW_UNVERIFIED_JWT" "0" (fun () ->
    let module S = Service.Make (struct
        let routes = []
      end)
    in
    expect_unverified_refused
      (S.run
         ~env
         ~port:0
         ~stop:(stopped ())
         ~drain_timeout_s:0.1
         ~metrics_auth:(jwt_cfg [])
         ()))
;;

(* SEC-009: a Jwks_url that is not https:// is a startup error. *)
let jwks_url_auth url =
  `Jwt
    Auth.
      { scopes = []
      ; verification =
          Verified_signature_required
            { issuer = "https://issuer.example.com"
            ; audience = "svc"
            ; algorithms = [ `RS256 ]
            ; key_source = Jwks_url url
            }
      }
;;

let run_with_jwks_url env ?(on_route = true) url =
  let auth = jwks_url_auth url in
  let module S = Service.Make (struct
      let routes = if on_route then [ Route.get "/jwt" ~auth get_json ] else []
    end)
  in
  S.run
    ~env
    ~port:0
    ~stop:(stopped ())
    ~drain_timeout_s:0.1
    ?metrics_auth:(if on_route then None else Some auth)
    ()
;;

let test_http_jwks_url_refused env () =
  List.iter
    (fun (url, on_route) ->
       match run_with_jwks_url env ~on_route url with
       | Error (`Config msg) ->
         Alcotest.(check bool) ("names the URL: " ^ url) true (contains url msg)
       | Ok () -> Alcotest.failf "a Jwks_url of %S must not start" url)
    [ "http://idp.example.com/jwks.json", true
    ; "idp.example.com/jwks.json", true
    ; "http://idp.example.com/jwks.json", false
    ]
;;

let test_https_jwks_url_starts env () =
  match run_with_jwks_url env "https://idp.example.com/jwks.json" with
  | Ok () -> ()
  | Error e -> Alcotest.fail (Service.run_error_to_string e)
;;

(* BUG-046: an external [stop] must reach the server. With nothing in flight it
   used to wait out the whole drain window and then report a drain timeout. *)
let test_external_stop_is_prompt env () =
  let module S = Service.Make (H) in
  let stop, stop_r = Promise.create () in
  let t0 = Unix.gettimeofday () in
  (match
     S.run
       ~env
       ~port:0
       ~stop
       ~shutdown_delay_s:0.0
       ~drain_timeout_s:3.0
       ~on_listen:(fun _ -> Promise.resolve stop_r ())
       ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Service.run_error_to_string e));
  let elapsed = Unix.gettimeofday () -. t0 in
  Alcotest.(check bool)
    (Printf.sprintf "returned in %.2fs, well inside the 3s drain window" elapsed)
    true
    (elapsed < 1.5)
;;

let test_malformed_port_is_config_error env () =
  with_env "PORT" "80800x" (fun () ->
    let module S = Service.Make (H) in
    (* An already-resolved stop on an OS-assigned port makes a missing check return
       [Ok ()] promptly, so the test fails instead of serving forever on 8080. *)
    let stop, stop_r = Promise.create () in
    Promise.resolve stop_r ();
    match S.run ~env ~port:0 ~stop ~shutdown_delay_s:0.0 ~drain_timeout_s:0.1 () with
    | Error (`Config msg) ->
      Alcotest.(check bool) "names PORT and the value" true (contains "80800x" msg)
    | Ok () -> Alcotest.fail "expected a malformed PORT to be a startup Config error")
;;

(* INFRA-073: on stop, readiness turns 503 at once while the listener keeps
   serving for [shutdown_delay_s], so Kubernetes can drop the endpoint before the
   pod stops accepting. *)
let test_readyz_flips_before_listener_closes env () =
  Switch.run (fun sw ->
    let port_p, port_r = Promise.create () in
    let stop, stop_r = Promise.create () in
    let finished, finished_r = Promise.create () in
    Fiber.fork ~sw (fun () ->
      let module S = Service.Make (H) in
      ignore
        (S.run
           ~env
           ~port:0
           ~stop
           ~shutdown_delay_s:1.5
           ~drain_timeout_s:0.1
           ~on_listen:(fun p -> Promise.resolve port_r p)
           ());
      Promise.resolve finished_r ());
    let port = Promise.await port_p in
    let ready_status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/readyz" () in
    Alcotest.(check int) "ready before stop" 200 ready_status;
    Promise.resolve stop_r ();
    Eio.Time.sleep env#clock 0.2;
    let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/readyz" () in
    Alcotest.(check int) "readyz is 503 once stopping" 503 status;
    let hello, _ = http_call env ~sw ~port ~meth:`GET ~path:"/hello" () in
    Alcotest.(check int) "requests still served during the delay" 200 hello;
    let live, _ = http_call env ~sw ~port ~meth:`GET ~path:"/healthz" () in
    Alcotest.(check int) "liveness is unaffected" 200 live;
    Alcotest.(check bool)
      "run has not returned during the delay"
      false
      (Promise.is_resolved finished);
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () -> Promise.await finished))
;;

let with_small_body_server env ~sw ?(max_body_bytes = 50) f =
  let port_p, port_r = Promise.create () in
  let stop, stop_r = Promise.create () in
  Fiber.fork ~sw (fun () ->
    let module S = Service.Make (Hauth) in
    S.run
      ~env
      ~port:0
      ~max_body_bytes
      ~stop
      ~shutdown_delay_s:0.0
      ~drain_timeout_s:0.1
      ~on_listen:(fun p -> Promise.resolve port_r p)
      ()
    |> Result.map_error Service.run_error_to_string
    |> function
    | Ok () -> ()
    | Error e -> failwith e);
  let port = Promise.await port_p in
  Fun.protect
    (fun () -> f port)
    ~finally:(fun () ->
      try Promise.resolve stop_r () with
      | _ -> ())
;;

let test_unauth_large_body_gets_401 env () =
  (* Without valid auth, a large body should be rejected as 401 before reading. *)
  Switch.run (fun sw ->
    with_small_body_server env ~sw (fun port ->
      let big_body = String.make 200 'x' in
      let status, _ =
        http_call env ~sw ~port ~meth:`POST ~path:"/protected-upload" ~body:big_body ()
      in
      Alcotest.(check int) "401 not 413" 401 status))
;;

let test_auth_oversized_body_gets_413 env () =
  (* With valid auth, an oversized body should return 413. *)
  Switch.run (fun sw ->
    with_small_body_server env ~sw (fun port ->
      let tok = make_jwt ~scopes:[ "write" ] () in
      let big_body = String.make 200 'x' in
      let status, _ =
        http_call
          env
          ~sw
          ~port
          ~meth:`POST
          ~path:"/protected-upload"
          ~headers:[ "authorization", "Bearer " ^ tok ]
          ~body:big_body
          ()
      in
      Alcotest.(check int) "413 when auth ok but body too large" 413 status))
;;

let test_public_oversized_body_gets_413 env () =
  (* Public routes still enforce body size limits. *)
  Switch.run (fun sw ->
    with_small_body_server env ~sw (fun port ->
      let big_body = String.make 200 'x' in
      let status, _ =
        http_call env ~sw ~port ~meth:`POST ~path:"/upload" ~body:big_body ()
      in
      Alcotest.(check int) "413 on oversized public upload" 413 status))
;;

(* BUG-053: an exception outside the handler used to close the connection with
   no response. A non-object JWT payload was one real trigger. *)
let test_non_object_jwt_payload_gets_401 env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let enc = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet in
      let tok = enc {|{"alg":"HS256"}|} ^ "." ^ enc "[]" ^ ".sig" in
      let status, _ =
        http_call
          env
          ~sw
          ~port
          ~meth:`GET
          ~path:"/protected"
          ~headers:[ "authorization", "Bearer " ^ tok ]
          ()
      in
      Alcotest.(check int) "status 401" 401 status))
;;

let test_boundary_turns_exceptions_into_500 _env () =
  let r =
    Service.For_testing.respond_or_500 (fun () ->
      raise (Sys_error "Mutex.lock: Resource deadlock avoided"))
  in
  Alcotest.(check int) "500" 500 r.Response.status;
  Alcotest.(check int)
    "a normal response passes through"
    201
    (Service.For_testing.respond_or_500 (fun () -> Response.created "x")).Response.status
;;

(* BUG-053: an exception raised in authentication, through dispatch itself. *)
let test_dispatch_turns_auth_exception_into_500 _env () =
  let enc = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet in
  let tok = enc {|{"alg":"RS256","kid":"k1"}|} ^ "." ^ enc "{}" ^ "." ^ enc "sig" in
  let auth =
    `Jwt
      Auth.
        { scopes = []
        ; verification =
            Verified_signature_required
              { issuer = "https://issuer.example.com"
              ; audience = "svc"
              ; algorithms = [ `RS256 ]
              ; key_source = Jwks_url "https://idp.example.com/raising/jwks.json"
              }
        }
  in
  let req =
    Http.Request.make
      ~meth:`GET
      ~headers:(Http.Header.of_list [ "authorization", "Bearer " ^ tok ])
      "/jwt"
  in
  let r =
    Service.For_testing.dispatch
      ~fetch_jwks:(fun _ -> failwith "boom")
      ~routes:[ Route.get "/jwt" ~auth get_json ]
      req
      (Cohttp_eio.Body.of_string "")
  in
  Alcotest.(check int) "500, not a dropped connection" 500 r.Response.status
;;

let () =
  Unix.putenv "SOL_ALLOW_UNVERIFIED_JWT" "1";
  Eio_main.run (fun env ->
    Alcotest.run
      "service"
      [ ( "built-ins"
        , [ Alcotest.test_case "GET /healthz → 200" `Quick (test_healthz env)
          ; Alcotest.test_case
              "GET /metrics, no renderer → 404"
              `Quick
              (test_metrics_no_renderer env)
          ] )
      ; ( "routing"
        , [ Alcotest.test_case "unknown path → 404" `Quick (test_not_found env)
          ; Alcotest.test_case "wrong method → 405" `Quick (test_method_not_allowed env)
          ; Alcotest.test_case "public route → 200" `Quick (test_public_route env)
          ; Alcotest.test_case "path param extracted" `Quick (test_path_param env)
          ; Alcotest.test_case "POST body echoed" `Quick (test_echo_body env)
          ] )
      ; ( "auth"
        , [ Alcotest.test_case "JWT route, no token → 401" `Quick (test_jwt_no_token env)
          ; Alcotest.test_case
              "JWT route, valid token → 200"
              `Quick
              (test_jwt_valid_token env)
          ; Alcotest.test_case
              "JWT route, wrong scope → 403"
              `Quick
              (test_jwt_missing_scope env)
          ; Alcotest.test_case
              "Unverified_dev_only without opt-in → startup Config error"
              `Quick
              (test_unverified_jwt_refused_without_opt_in env)
          ; Alcotest.test_case
              "Unverified_dev_only metrics_auth without opt-in → startup Config error"
              `Quick
              (test_unverified_metrics_auth_refused_without_opt_in env)
          ; Alcotest.test_case
              "Jwks_url not https → startup Config error"
              `Quick
              (test_http_jwks_url_refused env)
          ; Alcotest.test_case
              "Jwks_url https → starts"
              `Quick
              (test_https_jwks_url_starts env)
          ] )
      ; ( "resilience"
        , [ Alcotest.test_case
              "non-object JWT payload → 401, not a closed connection"
              `Quick
              (test_non_object_jwt_payload_gets_401 env)
          ; Alcotest.test_case
              "exception outside the handler → 500"
              `Quick
              (test_boundary_turns_exceptions_into_500 env)
          ; Alcotest.test_case
              "auth exception through dispatch → 500"
              `Quick
              (test_dispatch_turns_auth_exception_into_500 env)
          ; Alcotest.test_case
              "handler exception → 500, server survives"
              `Quick
              (test_handler_exception env)
          ; Alcotest.test_case
              "external stop on listen"
              `Quick
              (test_external_stop_on_listen env)
          ; Alcotest.test_case
              "external stop does not wait out the drain window"
              `Quick
              (test_external_stop_is_prompt env)
          ; Alcotest.test_case
              "readyz flips to 503 before the listener closes"
              `Quick
              (test_readyz_flips_before_listener_closes env)
          ; Alcotest.test_case
              "malformed PORT is a startup Config error"
              `Quick
              (test_malformed_port_is_config_error env)
          ] )
      ; ( "metrics"
        , [ Alcotest.test_case
              "requests counter with route label"
              `Quick
              (test_metrics_counter env)
          ; Alcotest.test_case
              "duration histogram present"
              `Quick
              (test_metrics_duration env)
          ; Alcotest.test_case
              "route label uses pattern not path"
              `Quick
              (test_metrics_route_pattern_label env)
          ] )
      ; ( "auth_before_body"
        , [ Alcotest.test_case
              "unauth + large body → 401 not 413"
              `Quick
              (test_unauth_large_body_gets_401 env)
          ; Alcotest.test_case
              "auth ok + oversized body → 413"
              `Quick
              (test_auth_oversized_body_gets_413 env)
          ; Alcotest.test_case
              "public route + oversized body → 413"
              `Quick
              (test_public_oversized_body_gets_413 env)
          ; Alcotest.test_case
              "api key file read failure is startup error"
              `Quick
              (test_api_key_file_error_is_startup_error env)
          ] )
      ])
;;
