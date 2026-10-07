(* Regression for sol-fab/sol#1274.

   A Sol-managed schema-registry endpoint behind the deployment's private CA
   must validate against that declared trust root, and must still fail closed
   when the CA is not declared. A real TLS handshake runs against the untrusted
   fixture in fixtures/ (CN=localhost, SAN localhost, absent from the system
   store). *)

(* The TLS handshake needs the RNG seeded; do it before any server or client
   fiber runs, rather than relying on whichever side gets there first. *)
let () = Mirage_crypto_rng_unix.use_default ()
let read_file path = In_channel.with_open_bin path In_channel.input_all

module Event = struct
  type t = { id : string }

  let topic_name = Kafka_service.topic_name_exn "sol-declared-ca-fixture"

  let schema =
    {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}
  ;;

  let partitions = 1
  let key t = Some t.id
  let encode t = `Assoc [ "id", `String t.id ]

  let decode = function
    | `Assoc [ ("id", `String id) ] -> Ok { id }
    | _ -> Error "expected an object with a string id"
  ;;
end

(* A TLS registry mock: performs the handshake with the fixture certificate and
   answers any request with a compatible-schema body. It listens on both
   loopback families, because `localhost` may resolve to either one. *)
let with_private_ca_registry env f =
  Eio.Switch.run
  @@ fun sw ->
  let cert =
    Result.get_ok (X509.Certificate.decode_pem (read_file "fixtures/cert.pem"))
  in
  let key = Result.get_ok (X509.Private_key.decode_pem (read_file "fixtures/key.pem")) in
  let server_config =
    Result.get_ok (Tls.Config.server ~certificates:(`Single ([ cert ], key)) ())
  in
  let body = {|{"is_compatible":true}|} in
  let serve conn =
    try
      let flow = Tls_eio.server_of_flow server_config conn in
      let ic = Eio.Buf_read.of_flow flow ~max_size:(256 * 1024) in
      ignore (Eio.Buf_read.line ic);
      let rec skip_headers () =
        if Eio.Buf_read.line ic = "" then () else skip_headers ()
      in
      skip_headers ();
      let response =
        Printf.sprintf
          "HTTP/1.1 200 OK\r\n\
           Content-Type: application/json\r\n\
           Content-Length: %d\r\n\
           Connection: close\r\n\
           \r\n\
           %s"
          (String.length body)
          body
      in
      Eio.Buf_write.with_flow flow (fun oc -> Eio.Buf_write.string oc response);
      Eio.Flow.close flow
    with
    | _ -> ()
  in
  let accept_loop socket =
    let rec loop () =
      match Eio.Net.accept ~sw socket with
      | conn, _addr ->
        serve conn;
        loop ()
      | exception _ -> ()
    in
    loop ()
  in
  let v4 = Eio.Net.listen ~backlog:5 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port =
    match Eio.Net.listening_addr v4 with
    | `Tcp (_, port) -> port
    | _ -> failwith "unexpected address family"
  in
  let listeners =
    match
      Eio.Net.listen ~backlog:5 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V6.loopback, port))
    with
    | v6 -> [ v4; v6 ]
    | exception _ -> [ v4 ]
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Fiber.all (List.map (fun socket () -> accept_loop socket) listeners);
    `Stop_daemon);
  f ~port
;;

let fixture_ca = Filename.concat (Sys.getcwd ()) "fixtures/cert.pem"
let registry_url ~port = Printf.sprintf "https://localhost:%d" port

let with_declared_ca ca f =
  Unix.putenv "KAFKA_SSL_CA_LOCATION" ca;
  Fun.protect ~finally:(fun () -> Unix.putenv "KAFKA_SSL_CA_LOCATION" "") f
;;

let test_declared_ca_is_trusted () =
  Eio_main.run
  @@ fun env ->
  with_private_ca_registry env (fun ~port ->
    with_declared_ca fixture_ca (fun () ->
      match
        Kafka_service.Schema.check
          ~net:env#net
          ~clock:env#clock
          ~registry_url:(registry_url ~port)
          (module Event)
      with
      | Ok () -> ()
      | Error e ->
        Windtrap.failf
          "the deployment's declared private CA was not honoured: %s"
          (Kafka_service.error_to_string e)))
;;

let test_undeclared_ca_fails_closed () =
  Eio_main.run
  @@ fun env ->
  with_private_ca_registry env (fun ~port ->
    with_declared_ca "" (fun () ->
      match
        Kafka_service.Schema.check
          ~net:env#net
          ~clock:env#clock
          ~registry_url:(registry_url ~port)
          (module Event)
      with
      | Ok () -> Windtrap.fail "an undeclared private CA must not be trusted"
      | Error _ -> ()))
;;

let test_explicit_ca_file_is_honoured () =
  Eio_main.run
  @@ fun env ->
  with_private_ca_registry env (fun ~port ->
    with_declared_ca "" (fun () ->
      match
        Kafka_service.Schema.check
          ~ca_file:fixture_ca
          ~net:env#net
          ~clock:env#clock
          ~registry_url:(registry_url ~port)
          (module Event)
      with
      | Ok () -> ()
      | Error e ->
        Windtrap.failf
          "an explicit ~ca_file was not honoured: %s"
          (Kafka_service.error_to_string e)))
;;

let test_unusable_ca_file_fails_closed () =
  Eio_main.run
  @@ fun env ->
  with_private_ca_registry env (fun ~port ->
    match
      Kafka_service.Schema.check
        ~ca_file:"fixtures/does-not-exist.pem"
        ~net:env#net
        ~clock:env#clock
        ~registry_url:(registry_url ~port)
        (module Event)
    with
    | Ok () ->
      Windtrap.fail "an unusable declared CA must fail, not fall back to the system store"
    | Error _ -> ())
;;

let () =
  let open Windtrap in
  run
    "kafka_service_declared_ca"
    [ Windtrap.group
        "declared_ca"
        [ test "trusts the deployment's declared private CA" test_declared_ca_is_trusted
        ; test "fails closed when no CA is declared" test_undeclared_ca_fails_closed
        ; test "honours an explicit ~ca_file" test_explicit_ca_file_is_honoured
        ; test
            "fails closed on an unusable declared CA"
            test_unusable_ca_file_fails_closed
        ]
    ]
;;
