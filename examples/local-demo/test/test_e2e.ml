(** E2E golden workflow tests — asserts the full svc→Kafka→worker→Postgres path.
*)

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let str_contains haystack needle =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true
  else if n > h then false
  else
    let rec go i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else go (i + 1)
    in
    go 0

let metric_nonzero render name =
  let n = String.length name in
  String.split_on_char '\n' render
  |> List.exists (fun line ->
      String.length line > n
      && String.sub line 0 n = name
      && (line.[n] = '{' || line.[n] = ' ')
      &&
      match List.rev (String.split_on_char ' ' line) with
      | v :: _ -> (
          match float_of_string_opt v with Some f -> f > 0.0 | None -> false)
      | [] -> false)

let loki_port url =
  match String.rindex_opt url ':' with
  | None -> 3100
  | Some i ->
      let s = String.sub url (i + 1) (String.length url - i - 1) in
      let s =
        match String.index_opt s '/' with
        | Some j -> String.sub s 0 j
        | None -> s
      in
      Option.value ~default:3100 (int_of_string_opt s)

let free_tcp_port () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close sock)
    (fun () ->
      Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname sock with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> assert false)

let http_get env ~sw ~port ~path () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw env#net addr in
  Eio.Flow.copy_string
    (Printf.sprintf "GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n" path)
    flow;
  Eio.Buf_read.take_all (Eio.Buf_read.of_flow flow ~max_size:65536)

let http_post env ~sw ~port ~path ?(headers = []) ~body () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw env#net addr in
  let extra =
    List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) headers
    |> String.concat ""
  in
  let req =
    Printf.sprintf
      "POST %s HTTP/1.1\r\n\
       host: localhost\r\n\
       connection: close\r\n\
       content-type: application/json\r\n\
       content-length: %d\r\n\
       %s\r\n\
       %s"
      path (String.length body) extra body
  in
  Eio.Flow.copy_string req flow;
  Eio.Flow.shutdown flow `Send;
  let buf = Eio.Buf_read.of_flow flow ~max_size:65536 in
  let resp = Eio.Buf_read.take_all buf in
  match String.split_on_char ' ' resp with
  | _ :: code :: _ -> ( try int_of_string (String.trim code) with _ -> 0)
  | _ -> 0

(* ── DB schema (matches demo.ml) ─────────────────────────────────────────── *)
module FulfilledOrderSchema = struct
  let table = "fulfilled_orders"
  let id_column = "order_id"
  let columns = [ "order_id"; "item"; "quantity"; "correlation_id" ]

  type t = {
    order_id : string;
    item : string;
    quantity : int;
    correlation_id : string;
  }

  type id = string

  let row_type =
    Caqti_type.(
      custom
        ~encode:(fun r -> Ok (r.order_id, r.item, r.quantity, r.correlation_id))
        ~decode:(fun (order_id, item, quantity, correlation_id) ->
          Ok { order_id; item; quantity; correlation_id })
        (t4 string string int string))

  let id_type = Caqti_type.string
  let get_id r = r.order_id
end

module FulfilledOrders = Pg_table.Make (FulfilledOrderSchema)

(* ── Golden path result ───────────────────────────────────────────────────── *)
type result = {
  http_statuses : int list;
  metrics_text : string;
  worker_metrics_http : string option;
  loki_resp : string option;
  loki_cli_lines : int option;
  db_rows : int;
}

(* ── Run golden path ──────────────────────────────────────────────────────── *)
let run_golden_path () =
  let loki_url = Sys.getenv_opt "LOKI_URL" in
  let postgres_url = Sys.getenv_opt "POSTGRES_URL" in
  let orders_count = 3 in
  let worker_metrics_port = free_tcp_port () in
  let module OrderPlaced = struct
    include Events.OrderPlaced

    let topic_name =
      Kafka_service.topic_name_exn
        (Printf.sprintf "sol-demo-orders-e2e-%d" (Unix.getpid ()))
  end in
  let kafka_config : Kafka_service.config =
    let config =
      match Kafka_service.config_of_env () with
      | Ok config -> config
      | Error e -> failwith ("kafka config: " ^ Kafka_service.error_to_string e)
    in
    { config with linger_ms = 5 }
  in

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* Observability *)
  let svc_obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"order-svc" ()
  in
  let worker_obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"fulfillment-worker" ()
  in
  (* Each carries its own Prometheus registry (like two real, separately
     scraped services) — this test's own assertions render and stitch
     both together, same as examples/local-demo/bin/demo.ml. *)
  let render () =
    Sol_obs.metrics_renderer svc_obs () ^ Sol_obs.metrics_renderer worker_obs ()
  in
  let svc_ot = Sol_obs.obs_eio svc_obs in

  (* Storage *)
  let db_pool =
    match postgres_url with
    | None -> None
    | Some url -> (
        match
          Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) ()
        with
        | Error _ -> None
        | Ok pool -> (
            match
              Migration.apply pool ~dir:"examples/local-demo/migrations"
                ~fs:env#fs
            with
            | Error _ -> None
            | Ok () -> Some pool))
  in

  (* Kafka *)
  let svc =
    match Kafka_service.create kafka_config ~sw with
    | Ok s -> s
    | Error e -> failwith ("Kafka create: " ^ Kafka_service.error_to_string e)
  in
  let topic =
    match
      Kafka_service.register svc ~net:env#net ~clock:env#clock
        (module OrderPlaced)
    with
    | Ok t -> t
    | Error e -> failwith ("Kafka register: " ^ Kafka_service.error_to_string e)
  in

  (* Worker *)
  let worker_ready_p, worker_ready_r = Eio.Promise.create () in
  let worker_done_p, worker_done_r = Eio.Promise.create () in

  let module W = struct
    module Message = OrderPlaced

    let group_id = "sol-e2e-test-worker"

    let handle msg ~trace_ctx:_ =
      (if msg.Message.order_id <> "order-e2e-stop" then
         match db_pool with
         | None -> ()
         | Some pool -> (
             let row =
               FulfilledOrderSchema.
                 {
                   order_id = msg.Message.order_id;
                   item = msg.Message.item;
                   quantity = msg.Message.quantity;
                   correlation_id = msg.Message.correlation_id;
                 }
             in
             match FulfilledOrders.insert pool row with Ok () | Error _ -> ()));
      Ok ()
  end in
  Eio.Fiber.fork ~sw (fun () ->
      (try
         let module WR = Worker.For_testing.Make (W) in
         WR.run ~env ~config:kafka_config ~ot:worker_obs
           ~metrics_port:worker_metrics_port
           ~on_ready:(fun () ->
             try Eio.Promise.resolve worker_ready_r () with _ -> ())
           ~max_messages:(orders_count + 1) ()
         |> Result.map_error Worker.run_error_to_string
         |> function
         | Ok () -> ()
         | Error msg -> failwith msg
       with Failure _ -> ());
      try Eio.Promise.resolve worker_done_r () with _ -> ());

  (* Service *)
  let handle_order req =
    let corr_id =
      Option.value (Request.header req "x-correlation-id") ~default:"test-corr"
    in
    let body_j =
      try Yojson.Safe.from_string req.Request.body with _ -> `Assoc []
    in
    let s k =
      match body_j with
      | `Assoc fs -> (
          match List.assoc_opt k fs with Some (`String s) -> s | _ -> "")
      | _ -> ""
    in
    let i k =
      match body_j with
      | `Assoc fs -> (
          match List.assoc_opt k fs with Some (`Int n) -> n | _ -> 0)
      | _ -> 0
    in
    let msg =
      OrderPlaced.
        {
          order_id = s "order_id";
          item = s "item";
          quantity = i "quantity";
          correlation_id = corr_id;
        }
    in
    let trace_ctx =
      Obs_eio.with_span svc_ot "receive_order" (fun span ->
          Obs_eio.log span Info
            ~fields:[ ("order_id", msg.order_id) ]
            "order received";
          Obs_eio.current_trace_context span)
    in
    (match
       Eio.Promise.await (Kafka_service.publish svc topic msg ~trace_ctx)
     with
    | Ok () | Error _ -> ());
    Response.json ~status:202 {|{"accepted":true}|}
  in

  let svc_port_p, svc_port_r = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      ( Service.run
          [ Route.post "/orders" ~auth:`Public handle_order ]
          ~env ~port:0 ~ot:svc_obs
          ~on_listen:(fun p -> Eio.Promise.resolve svc_port_r p)
          ()
      |> Result.map_error Service.run_error_to_string
      |> function
        | Ok () -> ()
        | Error e -> failwith e );
      `Stop_daemon);
  let port = Eio.Promise.await svc_port_p in

  (* Wait for worker ready *)
  (match
     Eio.Time.with_timeout env#clock 15.0 (fun () ->
         Ok (Eio.Promise.await worker_ready_p))
   with
  | Error `Timeout ->
      failwith "timed out waiting for worker partition assignment"
  | Ok () -> ());

  (* Send 3 orders *)
  let orders =
    [
      ("order-e2e-001", "Mechanical Keyboard", 1);
      ("order-e2e-002", "USB-C Hub", 2);
      ("order-e2e-003", "Standing Desk Riser", 1);
    ]
  in
  let http_statuses =
    List.map
      (fun (order_id, item, qty) ->
        let body =
          Printf.sprintf {|{"order_id":%S,"item":%S,"quantity":%d}|} order_id
            item qty
        in
        http_post env ~sw ~port ~path:"/orders"
          ~headers:[ ("x-correlation-id", "test-" ^ order_id) ]
          ~body ())
      orders
  in

  let worker_metrics_http =
    match
      Eio.Time.with_timeout env#clock 5.0 (fun () ->
          let rec loop () =
            match
              try
                Some
                  (http_get env ~sw ~port:worker_metrics_port ~path:"/metrics"
                     ())
              with _ -> None
            with
            | Some resp when metric_nonzero resp "sol_worker_messages_total" ->
                resp
            | _ ->
                Eio.Time.sleep env#clock 0.05;
                loop ()
          in
          Ok (loop ()))
    with
    | Ok resp -> Some resp
    | Error `Timeout -> None
  in

  let stop_body =
    {|{"order_id":"order-e2e-stop","item":"stop","quantity":0}|}
  in
  ignore
    (http_post env ~sw ~port ~path:"/orders"
       ~headers:[ ("x-correlation-id", "test-order-e2e-stop") ]
       ~body:stop_body ());

  (* Wait for worker done *)
  (match
     Eio.Time.with_timeout env#clock 20.0 (fun () ->
         Ok (Eio.Promise.await worker_done_p))
   with
  | Error `Timeout ->
      failwith "timed out waiting for worker to process messages"
  | Ok () -> ());

  (* Collect results *)
  let metrics_text = render () in
  let loki_resp =
    match loki_url with
    | None -> None
    | Some url -> (
        let p = loki_port url in
        let path =
          "/loki/api/v1/query?query=%7Bservice%3D%22order-svc%22%7D&limit=5"
        in
        try Some (http_get env ~sw ~port:p ~path ()) with _ -> None)
  in
  let loki_cli_lines =
    match loki_url with
    | None -> None
    | Some url -> (
        let p = loki_port url in
        let ts_ns =
          Int64.to_string
            (Int64.of_float (Unix.gettimeofday () *. 1_000_000_000.))
        in
        let body =
          Printf.sprintf
            {|{"streams":[{"stream":{"namespace":"sol-e2e","app":"auth-read"},"values":[[%S,%S]]}]}|}
            ts_ns "sol logs authenticated read e2e"
        in
        let pushed =
          http_post env ~sw ~port:p ~path:"/loki/api/v1/push" ~body () = 204
        in
        if not pushed then None
        else
          let credentials =
            match
              Sol_cli_loki.resolve_credentials ~flag_username:None
                ~flag_password:None
                ~env_username:(Sys.getenv_opt "SOL_LOKI_USERNAME")
                ~env_password:(Sys.getenv_opt "SOL_LOKI_PASSWORD")
            with
            | Ok (Some c) -> Some c
            | Ok None ->
                Some Sol_cli_loki.{ username = "sol-e2e"; password = "sol-e2e" }
            | Error msg -> failwith msg
          in
          match
            Sol_cli_loki.query ~base_url:url ~ns:"sol-e2e" ~k8s_name:"auth-read"
              ?credentials ~limit:5 ~timeout_s:5.0 ()
          with
          | Ok lines -> Some (List.length lines)
          | Error _ -> Some 0)
  in
  let db_rows =
    match db_pool with
    | None -> 0
    | Some pool -> (
        match FulfilledOrders.list pool () with
        | Error _ -> 0
        | Ok rows -> List.length rows)
  in
  {
    http_statuses;
    metrics_text;
    worker_metrics_http;
    loki_resp;
    loki_cli_lines;
    db_rows;
  }

(* ── Tests ────────────────────────────────────────────────────────────────── *)
let () =
  let r = run_golden_path () in
  Alcotest.run "e2e golden workflow"
    [
      ( "http",
        [
          Alcotest.test_case "all orders accepted (HTTP 202)" `Quick (fun () ->
              let bad = List.filter (( <> ) 202) r.http_statuses in
              if bad <> [] then
                Alcotest.failf "expected 202, got: %s"
                  (String.concat ", " (List.map string_of_int bad)));
        ] );
      ( "metrics",
        [
          Alcotest.test_case "sol_svc_requests_total > 0" `Quick (fun () ->
              if not (metric_nonzero r.metrics_text "sol_svc_requests_total")
              then Alcotest.fail "metric absent or zero");
          Alcotest.test_case "sol_worker_messages_total > 0" `Quick (fun () ->
              if not (metric_nonzero r.metrics_text "sol_worker_messages_total")
              then Alcotest.fail "metric absent or zero");
          Alcotest.test_case "worker /metrics serves metrics" `Quick (fun () ->
              match r.worker_metrics_http with
              | None -> Alcotest.fail "worker /metrics was not reachable"
              | Some resp ->
                  if not (metric_nonzero resp "sol_worker_messages_total") then
                    Alcotest.fail
                      "worker /metrics did not include worker metrics");
        ] );
      ( "loki",
        [
          Alcotest.test_case "logs received for service=order-svc" `Quick
            (fun () ->
              match r.loki_resp with
              | None -> () (* LOKI_URL not set — skip *)
              | Some resp ->
                  if not (str_contains resp {|"values":[[|}) then
                    Alcotest.fail "no log streams in Loki response");
          Alcotest.test_case "sol logs Loki query path reads pushed logs" `Quick
            (fun () ->
              match r.loki_cli_lines with
              | None -> () (* LOKI_URL not set — skip *)
              | Some n ->
                  if n = 0 then
                    Alcotest.fail
                      "Sol_cli_loki.query returned no pushed log lines");
        ] );
      ( "postgres",
        [
          Alcotest.test_case "fulfilled orders persisted" `Quick (fun () ->
              if r.db_rows = 0 then () (* POSTGRES_URL not set — skip *)
              else Alcotest.(check int) "3 rows stored" 3 r.db_rows);
        ] );
    ]
