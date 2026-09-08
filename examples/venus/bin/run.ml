(** Venus — Sol reference workspace
    ─────────────────────────────────────────────────────────────────────────
    Two autonomous domain teams collaborating through typed Kafka events:

      HTTP client
          │  POST /charges  { amount_cents, customer_id, currency }
          ▼
      payments / charge-svc  (sol-svc)
          │  Loki span: "receive_charge"
          │  Prometheus: sol_svc_requests_total, sol_svc_request_duration_seconds
          │  publishes Charged event with W3C traceparent header
          ▼
      Kafka  venus-payments-charges
          │
          ▼
      comms / notify-worker  (sol-worker)
          │  Loki span: "record_notification"  (linked to charge-svc span via trace)
          │  Prometheus: sol_worker_messages_total, sol_worker_message_duration_seconds
          │  records notification in PostgreSQL  (pg-eio)
          ▼
      Loki · Prometheus · PostgreSQL

    Run (from repo root):
      bash cli/platform/local/scripts/ensure-broker.sh
      bash cli/platform/local/scripts/ensure-postgres.sh       # optional
      bash cli/platform/local/scripts/ensure-loki.sh           # optional — stdout fallback
      bash cli/platform/local/scripts/ensure-grafana.sh        # optional

      KAFKA_BROKERS=localhost:9092 \
      POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
      LOKI_URL=http://localhost:3100 \
        dune exec examples/venus/bin/run.exe
*)

(* ── Config ─────────────────────────────────────────────────────────────── *)

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let loki_url        = env_nonempty "LOKI_URL"
let pushgateway_url = env_nonempty "PUSHGATEWAY_URL"
let postgres_url    = env_nonempty "POSTGRES_URL"

let require_kafka label = function
  | Ok value -> value
  | Error e  -> failwith (label ^ ": " ^ Kafka_service.error_to_string e)

let kafka_config : Kafka_service.config =
  { (Kafka_service.config_of_env () |> require_kafka "kafka config") with linger_ms = 5 }

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let sep = String.make 60 '-'
let say fmt = Printf.ksprintf (fun s -> Printf.printf "\n[venus] %s\n%!" s) fmt
let new_corr_id () = Printf.sprintf "c-%06x" (Random.int 0xFFFFFF)
let new_charge_id () = Printf.sprintf "ch_%08x%08x" (Random.bits ()) (Random.bits ())

let require_storage label = function
  | Ok value -> value
  | Error e  -> failwith (label ^ ": " ^ Pg_error.to_string e)

let create_db_pool ~sw ~stdenv url =
  Pg_db.create_pool ~url ~sw ~stdenv () |> require_storage "db pool"

let apply_venus_migrations ~fs pool =
  Migration.apply pool ~dir:"examples/venus/db/migrations"
    ~table:"venus_schema_migrations" ~fs
  |> require_storage "migrations"

let optional_db_pool ~sw ~stdenv ~fs = function
  | None ->
    Printf.printf "\n  Note: POSTGRES_URL not set — notifications will not be persisted.\n%!";
    None
  | Some url ->
    let pool = create_db_pool ~sw ~stdenv url in
    apply_venus_migrations ~fs pool;
    Printf.printf "\n  DB -> Postgres  (migrations applied)\n%!";
    Some pool

let create_registered_topic ~sw ~net ~clock () =
  say "registering topic %S ..." (Kafka_service.topic_name_to_string Charged.topic_name);
  let svc = Kafka_service.create kafka_config ~sw |> require_kafka "kafka create" in
  let topic =
    Kafka_service.register svc ~net ~clock (module Charged)
    |> require_kafka "kafka register"
  in
  say "topic ready.";
  svc, topic

let http_post env ~sw ~port ~path ?(headers=[]) ~body () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow  = Eio.Net.connect ~sw env#net addr in
  let extra = List.map (fun (k,v) -> Printf.sprintf "%s: %s\r\n" k v) headers
              |> String.concat "" in
  let req =
    Printf.sprintf
      "POST %s HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\
       content-type: application/json\r\ncontent-length: %d\r\n%s\r\n%s"
      path (String.length body) extra body
  in
  Eio.Flow.copy_string req flow;
  Eio.Flow.shutdown flow `Send;
  let buf = Eio.Buf_read.of_flow flow ~max_size:65536 in
  let resp = Eio.Buf_read.take_all buf in
  match String.split_on_char ' ' resp with
  | _ :: code :: _ -> (try int_of_string (String.trim code) with _ -> 0)
  | _              -> 0

(* ── Main ───────────────────────────────────────────────────────────────── *)

let () =
  Random.self_init ();
  Printf.printf "\n%s\n" sep;
  Printf.printf "  Venus — Sol Reference Workspace\n";
  Printf.printf "%s\n" sep;
  Printf.printf "  Teams:           payments (charge-svc)  ·  comms (notify-worker)\n";
  Printf.printf "  Kafka brokers:   %s\n" (String.concat "," kafka_config.brokers);
  Printf.printf "  Schema registry: %s\n" kafka_config.schema_registry_url;
  Printf.printf "  Loki:            %s\n" (Option.value ~default:"(stdout fallback)" loki_url);
  Printf.printf "  Pushgateway:     %s\n" (Option.value ~default:"(disabled)" pushgateway_url);
  Printf.printf "  Postgres:        %s\n%!" (Option.value ~default:"(disabled)" postgres_url);

  Eio_main.run @@ fun env ->

  (* ── Observability ─────────────────────────────────────────────────────── *)
  (match loki_url with
   | None -> Printf.printf "\n  Note: LOKI_URL not set — logs go to stdout.\n%!"
   | Some url -> Printf.printf "\n  Logs -> Loki at %s\n%!" url);
  let svc_obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"charge-svc" ~context:[("team", "payments")] ()
  in
  let worker_obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"notify-worker" ~context:[("team", "comms")] ()
  in
  (* charge-svc and notify-worker each carry their own Prometheus registry
     (like two real, separately-scraped services) — this demo's own
     snapshot/push stitches both together. *)
  let render () = Sol_obs.metrics_renderer svc_obs () ^ Sol_obs.metrics_renderer worker_obs () in
  let svc_ot    = Sol_obs.obs_eio svc_obs in
  let worker_ot = Sol_obs.obs_eio worker_obs in

  Eio.Switch.run @@ fun sw ->

  (* ── Storage (comms team) ───────────────────────────────────────────────── *)
  let db_pool =
    optional_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) ~fs:env#fs
      postgres_url
  in

  (* ── Kafka (shared infrastructure) ─────────────────────────────────────── *)
  let svc, topic = create_registered_topic ~sw ~net:env#net ~clock:env#clock () in

  (* ── comms / notify-worker ──────────────────────────────────────────────── *)
  let charges_count = 3 in
  let worker_ready_p, worker_ready_r = Eio.Promise.create () in
  let worker_done_p,  worker_done_r  = Eio.Promise.create () in

  let module W = Notify_worker.Make(struct
    let pool = db_pool
    let ot   = worker_ot
  end) in

  Eio.Fiber.fork ~sw (fun () ->
    (try
      let module WR = Worker.Make(W) in
      WR.run ~env ~config:kafka_config ~ot:worker_obs ~metrics_port:0
        ~on_ready:(fun () ->
          Printf.printf "[notify-worker] partition assigned — ready\n%!";
          (try Eio.Promise.resolve worker_ready_r () with _ -> ()))
        ~max_messages:charges_count
        ()
      |> Result.map_error Worker.run_error_to_string
      |> function Ok () -> () | Error msg -> failwith msg
    with Failure msg ->
      Printf.eprintf "[notify-worker] error: %s\n%!" msg);
    (try Eio.Promise.resolve worker_done_r () with _ -> ())
  );

  (* ── payments / charge-svc ──────────────────────────────────────────────── *)
  let handle_charge req =
    let corr_id  = Option.value (Request.header req "x-correlation-id")
                     ~default:(new_corr_id ()) in
    let body_j   = (try Yojson.Safe.from_string req.Request.body
                    with _ -> `Assoc []) in
    let s k = match body_j with
      | `Assoc fs -> (match List.assoc_opt k fs with Some (`String s) -> s | _ -> "")
      | _ -> "" in
    let i k = match body_j with
      | `Assoc fs -> (match List.assoc_opt k fs with Some (`Int n) -> n | _ -> 0)
      | _ -> 0 in
    let charge_id = new_charge_id () in
    let msg = Charged.{
      charge_id;
      amount_cents   = i "amount_cents";
      customer_id    = s "customer_id";
      currency       = (let c = s "currency" in if c = "" then "USD" else c);
      correlation_id = corr_id;
    } in
    let span_ot = Obs_eio.with_context svc_ot [("correlation_id", corr_id)] in
    let trace_ctx = Obs_eio.with_span span_ot "receive_charge" (fun span ->
      Obs_eio.log span Info
        ~fields:[("charge_id",    msg.charge_id);
                 ("customer_id",  msg.customer_id);
                 ("amount_cents", string_of_int msg.amount_cents);
                 ("currency",     msg.currency)]
        "charge received";
      Obs_eio.current_trace_context span
    ) in
    Printf.printf "[charge-svc]    received   charge=%-20s  customer=%-10s  %5d %s\n%!"
      msg.charge_id msg.customer_id msg.amount_cents msg.currency;
    (match Eio.Promise.await (Kafka_service.publish svc topic msg ~trace_ctx) with
     | Ok ()    -> ()
     | Error ke ->
       Printf.eprintf "[charge-svc]    publish error: %s\n%!" (Kafka.Error.to_string ke));
    Response.json ~status:202
      (Printf.sprintf {|{"charge_id":%S,"accepted":true}|} charge_id)
  in

  let svc_port_p, svc_port_r = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Service.run [ Route.post "/charges" ~auth:`Public handle_charge ]
      ~env ~port:0 ~ot:svc_obs
      ~on_listen:(fun p ->
        Printf.printf "[charge-svc]    listening on port %d\n%!" p;
        Eio.Promise.resolve svc_port_r p)
      ()
    |> Result.map_error Service.run_error_to_string
    |> (function Ok () -> () | Error e -> failwith e);
    `Stop_daemon
  );
  let port = Eio.Promise.await svc_port_p in

  (* ── Wait for notify-worker partition assignment ─────────────────────────── *)
  say "waiting for worker partition assignment (up to 15s) ...";
  (match Eio.Time.with_timeout env#clock 15.0 (fun () ->
     Ok (Eio.Promise.await worker_ready_p)) with
   | Error `Timeout -> failwith "timed out waiting for worker partition assignment"
   | Ok () -> ());

  (* ── Send 3 charges ─────────────────────────────────────────────────────── *)
  Printf.printf "\n%s\n%!" sep;
  let charges = [
    ("cust-001", 4999,  "USD");
    ("cust-002", 12000, "EUR");
    ("cust-001", 799,   "GBP");
  ] in
  List.iter (fun (customer_id, amount_cents, currency) ->
    let corr_id = new_corr_id () in
    let body = Printf.sprintf
      {|{"amount_cents":%d,"customer_id":%S,"currency":%S}|}
      amount_cents customer_id currency in
    let status = http_post env ~sw ~port ~path:"/charges"
                   ~headers:[("x-correlation-id", corr_id)]
                   ~body () in
    Printf.printf "[client]        POST /charges customer=%-10s  %5d %s  -> HTTP %d  corr=%s\n%!"
      customer_id amount_cents currency status corr_id
  ) charges;
  Printf.printf "%s\n%!" sep;

  (* ── Wait for notify-worker ─────────────────────────────────────────────── *)
  say "waiting for notify-worker to process all %d events (up to 20s) ..." charges_count;
  (match Eio.Time.with_timeout env#clock 20.0 (fun () ->
     Ok (Eio.Promise.await worker_done_p)) with
   | Error `Timeout ->
     Printf.eprintf "[venus] timed out waiting for worker\n%!"
   | Ok () -> ());
  say "all %d events processed." charges_count;

  (* ── PostgreSQL: show what the comms team recorded ─────────────────────── *)
  (match db_pool with
   | None -> ()
   | Some pool ->
     Printf.printf "\n%s\n" sep;
     Printf.printf "  Notifications in PostgreSQL  (comms team)\n";
     Printf.printf "%s\n" sep;
     (match Notification.list pool () with
      | Error e ->
        Printf.eprintf "  db query error: %s\n%!" (Pg_error.to_string e)
      | Ok rows ->
        List.iter (fun (r : Notification.t) ->
          Printf.printf "  %-20s  %-10s  %5d %s\n"
            r.charge_id r.customer_id r.amount_cents r.currency
        ) rows;
        Printf.printf "%s\n%!" sep));

  (* ── Prometheus snapshot ────────────────────────────────────────────────── *)
  Printf.printf "\n%s\n" sep;
  Printf.printf "  Prometheus metrics snapshot\n";
  Printf.printf "%s\n" sep;
  Printf.printf "%s\n%!" (render ());

  (match pushgateway_url with
   | None -> ()
   | Some url ->
     (match Obs_prometheus.push ~net:env#net ~clock:env#clock
              ~url ~job:"venus" render with
      | Ok ()   -> say "metrics pushed to %s" url
      | Error e -> Printf.eprintf "[venus] push failed: %s\n%!" (Obs_prometheus.push_error_to_string e)));

  Printf.printf "\n%s\n" sep;
  Printf.printf "  Done.\n";
  Printf.printf "  Grafana:  http://localhost:3000\n";
  Printf.printf "    Logs:    Explore > Loki > {service=~\".*\"} | logfmt\n";
  Printf.printf "    Metrics: Explore > Prometheus > sol_svc_requests_total\n";
  Printf.printf "%s\n%!" sep
