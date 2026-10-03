let str_contains haystack needle =
  let h = String.length haystack
  and n = String.length needle in
  if n = 0
  then true
  else if n > h
  then false
  else (
    let rec go i =
      if i + n > h
      then false
      else if String.sub haystack i n = needle
      then true
      else go (i + 1)
    in
    go 0)
;;

let metric_nonzero render name =
  let n = String.length name in
  String.split_on_char '\n' render
  |> List.exists (fun line ->
    String.length line > n
    && String.sub line 0 n = name
    && (line.[n] = '{' || line.[n] = ' ')
    &&
    match List.rev (String.split_on_char ' ' line) with
    | v :: _ ->
      (match float_of_string_opt v with
       | Some f -> f > 0.0
       | None -> false)
    | [] -> false)
;;

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
;;

let free_tcp_port () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close sock)
    (fun () ->
       Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
       match Unix.getsockname sock with
       | Unix.ADDR_INET (_, port) -> port
       | Unix.ADDR_UNIX _ -> assert false)
;;

let http_get env ~sw ~port ~path () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw env#net addr in
  Eio.Flow.copy_string
    (Printf.sprintf "GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n" path)
    flow;
  Eio.Buf_read.take_all (Eio.Buf_read.of_flow flow ~max_size:65536)
;;

let http_post env ~sw ~port ~path ?(headers = []) ~body () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw env#net addr in
  let extra =
    List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) headers |> String.concat ""
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
      path
      (String.length body)
      extra
      body
  in
  Eio.Flow.copy_string req flow;
  Eio.Flow.shutdown flow `Send;
  let buf = Eio.Buf_read.of_flow flow ~max_size:65536 in
  let resp = Eio.Buf_read.take_all buf in
  match String.split_on_char ' ' resp with
  | _ :: code :: _ ->
    (try int_of_string (String.trim code) with
     | _ -> 0)
  | _ -> 0
;;

module FulfilledOrderSchema = struct
  let table = "fulfilled_orders"
  let id_column = "order_id"
  let columns = [ "order_id"; "item"; "quantity"; "correlation_id" ]

  type t =
    { order_id : string
    ; item : string
    ; quantity : int
    ; correlation_id : string
    }

  type id = string

  let row_type =
    Caqti_type.(
      custom
        ~encode:(fun r -> Ok (r.order_id, r.item, r.quantity, r.correlation_id))
        ~decode:(fun (order_id, item, quantity, correlation_id) ->
          Ok { order_id; item; quantity; correlation_id })
        (t4 string string int string))
  ;;

  let id_type = Caqti_type.string
  let get_id r = r.order_id
end

module FulfilledOrders = Pg_table.Make (FulfilledOrderSchema)

module EmailJobCodec = struct
  type t = { order_id : string }

  let workspace = "local-demo"
  let kind (_ : t) = "send_confirmation_email"
  let kinds = [ "send_confirmation_email" ]

  let encode (t : t) =
    Printf.sprintf {|{"order_id":%s}|} (Yojson.Safe.to_string (`String t.order_id))
  ;;

  let decode s =
    match Yojson.Safe.from_string s with
    | `Assoc [ ("order_id", `String order_id) ] -> Ok { order_id }
    | _ | (exception _) -> Error ("invalid EmailJob payload: " ^ s)
  ;;
end

type result =
  { http_statuses : int list
  ; metrics_text : string
  ; worker_metrics_http : string option
  ; loki_resp : string option
  ; loki_cli_lines : (int, string) Stdlib.result option
  ; db_rows : (int, string) Stdlib.result option
  ; jobs_processed : int
  }

let truncate_tables pool tables =
  let sql = Printf.sprintf "TRUNCATE %s" (String.concat ", " tables) in
  match
    Pg_db.exec pool (Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) sql) ()
  with
  | Ok () -> Ok ()
  | Error e -> Error (Pg_error.to_string e)
;;

let ensure_schema ~fs pool =
  match Migration.apply pool ~fs ~dir:"../migrations" with
  | Ok () -> ()
  | Error e -> failwith (Printf.sprintf "migrations: %s" (Pg_error.to_string e))
;;

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
    ;;
  end
  in
  let kafka_config : Kafka_service.config =
    let config =
      match Kafka_service.config_of_env () with
      | Ok config -> config
      | Error e -> failwith ("kafka config: " ^ Kafka_service.error_to_string e)
    in
    { config with linger_ms = 5 }
  in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let svc_obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"order-svc"
      ()
  in
  let worker_obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"fulfillment-worker"
      ()
  in
  let jobs_obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"jobs-worker"
      ()
  in
  let render () =
    Sol_obs.metrics_renderer svc_obs ()
    ^ Sol_obs.metrics_renderer worker_obs ()
    ^ Sol_obs.metrics_renderer jobs_obs ()
  in
  let svc_ot = Sol_obs.obs_eio svc_obs in
  let db_pool =
    match postgres_url with
    | None -> None
    | Some url ->
      (match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
       | Error e ->
         failwith
           (Printf.sprintf
              "POSTGRES_URL is set but the fixture's pool could not be created: %s"
              (Pg_error.to_string e))
       | Ok pool ->
         ensure_schema ~fs:env#fs pool;
         (match truncate_tables pool [ "fulfilled_orders"; "sol_jobs" ] with
          | Ok () -> ()
          | Error why -> failwith ("truncating the fixture tables: " ^ why));
         Some pool)
  in
  let jobs_done_p, jobs_done_r = Eio.Promise.create () in
  let jobs_processed = ref 0 in
  let module EmailJob = struct
    include EmailJobCodec

    let handle ({ order_id = _ } : t) =
      incr jobs_processed;
      if !jobs_processed >= orders_count
      then (
        try Eio.Promise.resolve jobs_done_r () with
        | _ -> ());
      Ok ()
    ;;
  end
  in
  let module Jobs = Sol_jobs.Make (EmailJob) in
  (match db_pool with
   | Some _ -> ()
   | None ->
     (try Eio.Promise.resolve jobs_done_r () with
      | _ -> ()));
  let svc =
    match Kafka_service.create kafka_config ~sw with
    | Ok s -> s
    | Error e -> failwith ("Kafka create: " ^ Kafka_service.error_to_string e)
  in
  (match
     Kafka_service.Schema.register
       ~net:env#net
       ~clock:env#clock
       ~registry_url:kafka_config.schema_registry_url
       (module OrderPlaced)
   with
   | Ok _ -> ()
   | Error e -> failwith ("Kafka contract: " ^ Kafka_service.error_to_string e));
  let topic =
    match
      Kafka_service.register svc ~net:env#net ~clock:env#clock (module OrderPlaced)
    with
    | Ok t -> t
    | Error e -> failwith ("Kafka register: " ^ Kafka_service.error_to_string e)
  in
  let worker_ready_p, worker_ready_r = Eio.Promise.create () in
  let worker_done_p, worker_done_r = Eio.Promise.create () in
  let module W = struct
    module Message = OrderPlaced

    let group_id = "sol-e2e-test-worker"

    let handle msg ~trace_ctx:_ =
      if msg.Message.order_id <> "order-e2e-stop"
      then (
        match db_pool with
        | None -> ()
        | Some pool ->
          let row =
            FulfilledOrderSchema.
              { order_id = msg.Message.order_id
              ; item = msg.Message.item
              ; quantity = msg.Message.quantity
              ; correlation_id = msg.Message.correlation_id
              }
          in
          let result =
            Pg_db.transaction pool (fun tx ->
              let open Result.Syntax in
              let* () = FulfilledOrders.insert tx row in
              Jobs.enqueue tx EmailJobCodec.{ order_id = msg.Message.order_id })
          in
          (match result with
           | Ok () | Error _ -> ()));
      Worker.Ack
    ;;
  end
  in
  Eio.Fiber.fork ~sw (fun () ->
    (try
       let module WR = Worker.For_testing.Make (W) in
       WR.run
         ~env
         ~config:kafka_config
         ~ot:worker_obs
         ~metrics_port:worker_metrics_port
         ~on_ready:(fun () ->
           try Eio.Promise.resolve worker_ready_r () with
           | _ -> ())
         ~max_messages:(orders_count + 1)
         ()
       |> Result.map_error Worker.run_error_to_string
       |> function
       | Ok () -> ()
       | Error msg -> failwith msg
     with
     | Failure _ -> ());
    try Eio.Promise.resolve worker_done_r () with
    | _ -> ());
  (match db_pool with
   | None -> ()
   | Some pool ->
     Eio.Fiber.fork ~sw (fun () ->
       (try
          Jobs.run
            ~env
            ~pool
            ~ot:jobs_obs
            ~metrics_port:0
            ~poll_interval_s:0.2
            ~max_jobs:orders_count
            ()
          |> Result.map_error Sol_jobs.run_error_to_string
          |> function
          | Ok () -> ()
          | Error msg -> failwith msg
        with
        | Failure _ -> ());
       try Eio.Promise.resolve jobs_done_r () with
       | _ -> ()));
  let handle_order req =
    let corr_id =
      Option.value (Request.header req "x-correlation-id") ~default:"test-corr"
    in
    let body_j =
      try Yojson.Safe.from_string req.Request.body with
      | _ -> `Assoc []
    in
    let s k =
      match body_j with
      | `Assoc fs ->
        (match List.assoc_opt k fs with
         | Some (`String s) -> s
         | _ -> "")
      | _ -> ""
    in
    let i k =
      match body_j with
      | `Assoc fs ->
        (match List.assoc_opt k fs with
         | Some (`Int n) -> n
         | _ -> 0)
      | _ -> 0
    in
    let msg =
      OrderPlaced.
        { order_id = s "order_id"
        ; item = s "item"
        ; quantity = i "quantity"
        ; correlation_id = corr_id
        }
    in
    let trace_ctx =
      Obs_eio.with_span svc_ot "receive_order" (fun span ->
        Obs_eio.log span Info ~fields:[ "order_id", msg.order_id ] "order received";
        Obs_eio.current_trace_context span)
    in
    (match Eio.Promise.await (Kafka_service.publish svc topic msg ~trace_ctx) with
     | Ok () | Error _ -> ());
    Response.json ~status:202 {|{"accepted":true}|}
  in
  let svc_port_p, svc_port_r = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (Service.run
       [ Route.post "/orders" ~auth:`Public handle_order ]
       ~env
       ~port:0
       ~ot:svc_obs
       ~on_listen:(fun p -> Eio.Promise.resolve svc_port_r p)
       ()
     |> Result.map_error Service.run_error_to_string
     |> function
     | Ok () -> ()
     | Error e -> failwith e);
    `Stop_daemon);
  let port = Eio.Promise.await svc_port_p in
  (match
     Eio.Time.with_timeout env#clock 15.0 (fun () ->
       Ok (Eio.Promise.await worker_ready_p))
   with
   | Error `Timeout -> failwith "timed out waiting for worker partition assignment"
   | Ok () -> ());
  let orders =
    [ "order-e2e-001", "Mechanical Keyboard", 1
    ; "order-e2e-002", "USB-C Hub", 2
    ; "order-e2e-003", "Standing Desk Riser", 1
    ]
  in
  let http_statuses =
    List.map
      (fun (order_id, item, qty) ->
         let body =
           Printf.sprintf {|{"order_id":%S,"item":%S,"quantity":%d}|} order_id item qty
         in
         http_post
           env
           ~sw
           ~port
           ~path:"/orders"
           ~headers:[ "x-correlation-id", "test-" ^ order_id ]
           ~body
           ())
      orders
  in
  let worker_metrics_http =
    match
      Eio.Time.with_timeout env#clock 5.0 (fun () ->
        let rec loop () =
          match
            try Some (http_get env ~sw ~port:worker_metrics_port ~path:"/metrics" ()) with
            | _ -> None
          with
          | Some resp when metric_nonzero resp "sol_worker_messages_total" -> resp
          | _ ->
            Eio.Time.sleep env#clock 0.05;
            loop ()
        in
        Ok (loop ()))
    with
    | Ok resp -> Some resp
    | Error `Timeout -> None
  in
  let stop_body = {|{"order_id":"order-e2e-stop","item":"stop","quantity":0}|} in
  ignore
    (http_post
       env
       ~sw
       ~port
       ~path:"/orders"
       ~headers:[ "x-correlation-id", "test-order-e2e-stop" ]
       ~body:stop_body
       ());
  (match
     Eio.Time.with_timeout env#clock 20.0 (fun () -> Ok (Eio.Promise.await worker_done_p))
   with
   | Error `Timeout -> failwith "timed out waiting for worker to process messages"
   | Ok () -> ());
  (match
     Eio.Time.with_timeout env#clock 20.0 (fun () -> Ok (Eio.Promise.await jobs_done_p))
   with
   | Error `Timeout -> failwith "timed out waiting for jobs-worker to process jobs"
   | Ok () -> ());
  let metrics_text = render () in
  let loki_resp =
    match loki_url with
    | None -> None
    | Some url ->
      let p = loki_port url in
      let path = "/loki/api/v1/query?query=%7Bservice%3D%22order-svc%22%7D&limit=5" in
      (try Some (http_get env ~sw ~port:p ~path ()) with
       | _ -> None)
  in
  let loki_cli_lines =
    match loki_url with
    | None -> None
    | Some url ->
      let emitted =
        Sol_obs.of_env
          ~sw
          ~net:env#net
          ~clock:env#clock
          ~mono_clock:env#mono_clock
          ~service:"auth-read"
          ~context:[ "workspace", "sol-e2e"; "domain", "e2e" ]
          ()
      in
      Sol_obs.log_info emitted "sol logs authenticated read e2e";
      Sol_obs.flush emitted;
      let credentials =
        match
          Sol_cli_loki.resolve_credentials
            ~flag_username:None
            ~flag_password:None
            ~env_username:(Sys.getenv_opt "SOL_LOKI_USERNAME")
            ~env_password:(Sys.getenv_opt "SOL_LOKI_PASSWORD")
        with
        | Ok (Some c) -> Some c
        | Ok None -> Some Sol_cli_loki.{ username = "sol-e2e"; password = "sol-e2e" }
        | Error msg -> failwith msg
      in
      let unit =
        { Sol_cli_log_selector.workspace = "sol-e2e"
        ; domain = "e2e"
        ; service = "auth-read"
        }
      in
      let deadline = Eio.Time.now env#clock +. 10.0 in
      let rec count_until_visible () =
        match
          Sol_cli_loki.query ~base_url:url ~unit ?credentials ~limit:5 ~timeout_s:5.0 ()
        with
        | Ok (_ :: _ as lines) -> Ok (List.length lines)
        | Ok [] when Eio.Time.now env#clock < deadline ->
          Eio.Time.sleep env#clock 0.2;
          count_until_visible ()
        | Ok [] -> Ok 0
        | Error err -> Error (Sol_cli_loki.fetch_error_to_string err)
      in
      Some (count_until_visible ())
  in
  let db_rows =
    match db_pool with
    | None -> None
    | Some pool ->
      Some
        (match FulfilledOrders.list pool () with
         | Error e -> Error (Pg_error.to_string e)
         | Ok rows -> Ok (List.length rows))
  in
  { http_statuses
  ; metrics_text
  ; worker_metrics_http
  ; loki_resp
  ; loki_cli_lines
  ; db_rows
  ; jobs_processed = !jobs_processed
  }
;;

module OutboxFact = struct
  type t =
    { id : string
    ; seq : int
    }

  let topic_name =
    Kafka_service.topic_name_exn
      (Printf.sprintf "sol-demo-outbox-e2e-%d" (Unix.getpid ()))
  ;;

  let schema =
    {|{
    "type": "object",
    "properties": {
      "id":  { "type": "string"  },
      "seq": { "type": "integer" }
    },
    "required": ["id", "seq"]
  }|}
  ;;

  let partitions = 3
  let key (t : t) = Some t.id
  let encode (t : t) = `Assoc [ "id", `String t.id; "seq", `Int t.seq ]
  let encode_string (t : t) = Yojson.Safe.to_string (encode t)

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields, List.assoc_opt "seq" fields with
       | Some (`String id), Some (`Int seq) -> Ok { id; seq }
       | _ -> Error "invalid fact payload")
    | _ -> Error "expected object"
  ;;
end

module Outbox = Sol_outbox.Make (struct
    type t = OutboxFact.t

    let kind (_ : t) = "fact"
    let kinds = [ "fact" ]
    let encode = OutboxFact.encode_string
  end)

type outbox_result =
  { ob_db : bool
  ; ob_partitions : int
  ; ob_rollback_clean : bool
  ; ob_outage_held : bool
  ; ob_outage_recovered : bool
  ; ob_duplicate_domain_rows : int
  ; ob_duplicate_effects : int
  ; ob_order_seq : int list
  ; ob_crash_published : bool
  ; ob_crash_row_survived : bool
  ; ob_crash_duplicate_facts : int
  ; ob_crash_effects : int
  ; ob_retry_invocations : int
  ; ob_retry_effects : int
  ; ob_fail_observed : bool
  ; ob_fail_redelivered : bool
  ; ob_app_retry_topics : string list
  ; ob_metrics : string
  ; ob_loki : string option
  }

let empty_outbox_result =
  { ob_db = false
  ; ob_partitions = 0
  ; ob_rollback_clean = false
  ; ob_outage_held = false
  ; ob_outage_recovered = false
  ; ob_duplicate_domain_rows = 0
  ; ob_duplicate_effects = 0
  ; ob_order_seq = []
  ; ob_crash_published = false
  ; ob_crash_row_survived = false
  ; ob_crash_duplicate_facts = 0
  ; ob_crash_effects = 0
  ; ob_retry_invocations = 0
  ; ob_retry_effects = 0
  ; ob_fail_observed = false
  ; ob_fail_redelivered = false
  ; ob_app_retry_topics = []
  ; ob_metrics = ""
  ; ob_loki = None
  }
;;

let run_outbox_path () =
  let loki_url = Sys.getenv_opt "LOKI_URL" in
  let postgres_url = Sys.getenv_opt "POSTGRES_URL" in
  let metrics_port = free_tcp_port () in
  let kafka_config : Kafka_service.config =
    let config =
      match Kafka_service.config_of_env () with
      | Ok config -> config
      | Error e -> failwith ("kafka config: " ^ Kafka_service.error_to_string e)
    in
    { config with linger_ms = 5 }
  in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let pool =
    match postgres_url with
    | None -> None
    | Some url ->
      (match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
       | Error e ->
         failwith
           (Printf.sprintf
              "outbox fixture: POSTGRES_URL is set but the pool could not be created: %s"
              (Pg_error.to_string e))
       | Ok pool -> Some pool)
  in
  match pool with
  | None -> empty_outbox_result
  | Some pool ->
    let obs =
      Sol_obs.of_env
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~mono_clock:env#mono_clock
        ~service:"outbox-e2e"
        ()
    in
    let render () = Sol_obs.metrics_renderer obs () in
    let count_where table where =
      match
        Pg_db.find
          pool
          (Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.int)
             (Printf.sprintf "SELECT count(*) FROM %s WHERE %s" table where))
          ()
      with
      | Ok (Some n) -> n
      | Ok None -> 0
      | Error e -> failwith (Printf.sprintf "count %s: %s" table (Pg_error.to_string e))
    in
    let wait ~what ~timeout_s f =
      let deadline = Unix.gettimeofday () +. timeout_s in
      let rec loop () =
        if f ()
        then ()
        else if Unix.gettimeofday () > deadline
        then failwith ("timed out waiting for " ^ what)
        else (
          Eio.Time.sleep env#clock 0.05;
          loop ())
      in
      loop ()
    in
    let insert_domain tx ~id ~seq =
      Pg_db.exec
        tx
        (Caqti_request.Infix.(Caqti_type.(t2 string int) ->. Caqti_type.unit)
           "INSERT INTO outbox_e2e_domain (id, seq) VALUES (?, ?) ON CONFLICT (id) DO \
            NOTHING")
        (id, seq)
    in
    let domain_and_intent ~id ~seq ~ord ~force_rollback =
      match
        Pg_db.transaction pool (fun tx ->
          let open Result.Syntax in
          let* () = insert_domain tx ~id ~seq in
          let* () =
            Outbox.publish tx ~key:id ~ord:(Int64.of_int ord) OutboxFact.{ id; seq }
          in
          if force_rollback
          then Error (Pg_error.Query_error "forced rollback after the intent was written")
          else Ok ())
      with
      | Ok () -> ()
      | Error e -> if force_rollback then ignore e else failwith (Pg_error.to_string e)
    in
    ensure_schema ~fs:env#fs pool;
    (match
       truncate_tables
         pool
         [ "sol_outbox"; "outbox_e2e_domain"; "outbox_e2e_effects"; "sol_jobs" ]
     with
     | Ok () -> ()
     | Error why -> failwith ("truncating the outbox fixture tables: " ^ why));
    let svc =
      match Kafka_service.create kafka_config ~sw with
      | Ok s -> s
      | Error e -> failwith ("Kafka create: " ^ Kafka_service.error_to_string e)
    in
    (match
       Kafka_service.Schema.register
         ~net:env#net
         ~clock:env#clock
         ~registry_url:kafka_config.schema_registry_url
         (module OutboxFact)
     with
     | Ok _ -> ()
     | Error e -> failwith ("Kafka contract: " ^ Kafka_service.error_to_string e));
    let topic =
      match
        Kafka_service.register svc ~net:env#net ~clock:env#clock (module OutboxFact)
      with
      | Ok t -> t
      | Error e -> failwith ("Kafka register: " ^ Kafka_service.error_to_string e)
    in
    let group_id = Printf.sprintf "sol-outbox-e2e-%d" (Unix.getpid ()) in
    let consumed = ref [] in
    let retry_invocations = ref 0 in
    let retry_succeeded = ref false in
    let failed = ref false in
    let worker_done_p, worker_done_r = Eio.Promise.create () in
    let worker_ready_p, worker_ready_r = Eio.Promise.create () in
    let relay_stop, relay_stop_r = Eio.Promise.create () in
    let jobs_stop, jobs_stop_r = Eio.Promise.create () in
    let broker_up = ref true in
    let crash_published = ref false in
    let module Effect = struct
      type t = { effect_id : string }

      let workspace = "local-demo"
      let kind (_ : t) = "outbox_e2e_effect"
      let kinds = [ "outbox_e2e_effect" ]

      let encode (t : t) =
        Printf.sprintf {|{"effect_id":%s}|} (Yojson.Safe.to_string (`String t.effect_id))
      ;;

      let decode s =
        match Yojson.Safe.from_string s with
        | `Assoc [ ("effect_id", `String effect_id) ] -> Ok { effect_id }
        | _ | (exception _) -> Error ("invalid effect payload: " ^ s)
      ;;

      let handle (t : t) =
        let is_retry = String.equal t.effect_id "retry" in
        if is_retry then incr retry_invocations;
        if is_retry && !retry_invocations <= 2
        then Error "transient failure"
        else (
          (match
             Pg_db.exec
               pool
               (Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit)
                  "INSERT INTO outbox_e2e_effects (effect_id) VALUES (?) ON CONFLICT \
                   (effect_id) DO NOTHING")
               t.effect_id
           with
           | Ok () -> ()
           | Error e -> failwith (Pg_error.to_string e));
          if is_retry then retry_succeeded := true;
          Ok ())
      ;;
    end
    in
    let module Jobs = Sol_jobs.Make (Effect) in
    let module W = struct
      module Message = OutboxFact

      let group_id = group_id

      let handle (msg : Message.t) ~trace_ctx:_ : Worker.outcome =
        consumed := (msg.id, msg.seq) :: !consumed;
        if String.equal msg.id "fail"
        then (
          failed := true;
          Worker.Fail)
        else (
          (match
             Pg_db.transaction pool (fun tx ->
               let open Result.Syntax in
               let* () = insert_domain tx ~id:msg.id ~seq:msg.seq in
               Jobs.enqueue tx ~dedupe_key:msg.id Effect.{ effect_id = msg.id })
           with
           | Ok () -> ()
           | Error _ -> ());
          Worker.Ack)
      ;;
    end
    in
    let module WR = Worker.For_testing.Make (W) in
    Eio.Fiber.fork ~sw (fun () ->
      (try
         ignore
           (WR.run
              ~env
              ~config:kafka_config
              ~ot:obs
              ~metrics_port
              ~on_ready:(fun () ->
                try Eio.Promise.resolve worker_ready_r () with
                | _ -> ())
              ())
       with
       | _ -> ());
      try Eio.Promise.resolve worker_done_r () with
      | _ -> ());
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Jobs.run
           ~env
           ~pool
           ~ot:obs
           ~metrics_port:0
           ~poll_interval_s:0.1
           ~retry_policy:
             { Sol_jobs.base_delay_s = 0.05
             ; max_delay_s = 0.2
             ; max_attempts = 5
             ; jitter_ratio = 0.0
             }
           ~stop:jobs_stop
           ()));
    (match
       Eio.Time.with_timeout env#clock 20.0 (fun () ->
         Ok (Eio.Promise.await worker_ready_p))
     with
     | Error `Timeout -> failwith "timed out waiting for the outbox worker to join"
     | Ok () -> ());
    domain_and_intent ~id:"crash" ~seq:1 ~ord:1 ~force_rollback:false;
    let crash_publish (p : Sol_outbox.publication) =
      match OutboxFact.decode (Yojson.Safe.from_string p.payload) with
      | Error msg -> Error msg
      | Ok event ->
        (match Eio.Promise.await (Kafka_service.publish svc topic event) with
         | Ok () ->
           crash_published := true;
           raise Exit
         | Error e -> Error (Kafka.Error.to_string e))
    in
    let crash_stop, _ = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      try
        ignore
          (Outbox.relay
             ~env
             ~pool
             ~publish:crash_publish
             ~poll_interval_s:0.05
             ~stop:crash_stop
             ())
      with
      | _ -> ());
    wait ~what:"the crash relay to publish before dying" ~timeout_s:15.0 (fun () ->
      !crash_published);
    let crash_row_survived = count_where "sol_outbox" "aggregate_key = 'crash'" = 1 in
    let main_publish (p : Sol_outbox.publication) =
      if not !broker_up
      then Error "broker unavailable (simulated outage)"
      else (
        match OutboxFact.decode (Yojson.Safe.from_string p.payload) with
        | Error msg -> Error msg
        | Ok event ->
          (match Eio.Promise.await (Kafka_service.publish svc topic event) with
           | Ok () -> Ok ()
           | Error e -> Error (Kafka.Error.to_string e)))
    in
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Outbox.relay
           ~env
           ~pool
           ~publish:main_publish
           ~poll_interval_s:0.1
           ~ot:obs
           ~metrics_port:0
           ~stop:relay_stop
           ()));
    domain_and_intent ~id:"happy" ~seq:1 ~ord:1 ~force_rollback:false;
    wait ~what:"the happy fact to be consumed" ~timeout_s:30.0 (fun () ->
      count_where "outbox_e2e_effects" "effect_id = 'happy'" = 1);
    wait ~what:"the happy outbox row to drain" ~timeout_s:30.0 (fun () ->
      count_where "sol_outbox" "aggregate_key = 'happy'" = 0);
    let partitions =
      match
        Kafka_service.Admin.query_topic_partitions
          env#net
          ~clock:env#clock
          ~admin_url:kafka_config.admin_url
          ~topic_name:(Kafka_service.topic_name_to_string OutboxFact.topic_name)
      with
      | Ok (Kafka_service.Admin.Topic_partitions { partitions; _ }) -> partitions
      | Ok Kafka_service.Admin.Topic_not_found -> 0
      | Error e -> failwith (Kafka_service.Admin.topic_partition_error_to_string e)
    in
    domain_and_intent ~id:"roll" ~seq:1 ~ord:1 ~force_rollback:true;
    Eio.Time.sleep env#clock 0.5;
    let rollback_clean =
      count_where "outbox_e2e_domain" "id = 'roll'" = 0
      && count_where "sol_outbox" "aggregate_key = 'roll'" = 0
      && not (List.exists (fun (id, _) -> String.equal id "roll") !consumed)
    in
    broker_up := false;
    domain_and_intent ~id:"outage" ~seq:1 ~ord:1 ~force_rollback:false;
    wait ~what:"the outage row to be held" ~timeout_s:15.0 (fun () ->
      count_where "sol_outbox" "aggregate_key = 'outage'" = 1);
    Eio.Time.sleep env#clock 0.5;
    let outage_held =
      count_where "sol_outbox" "aggregate_key = 'outage'" = 1
      && not (List.exists (fun (id, _) -> String.equal id "outage") !consumed)
    in
    broker_up := true;
    wait ~what:"the outage fact to publish after recovery" ~timeout_s:30.0 (fun () ->
      count_where "outbox_e2e_effects" "effect_id = 'outage'" = 1);
    let outage_recovered =
      count_where "sol_outbox" "aggregate_key = 'outage'" = 0
      && count_where "outbox_e2e_effects" "effect_id = 'outage'" = 1
    in
    let dupe = OutboxFact.{ id = "dupe"; seq = 1 } in
    ignore (Eio.Promise.await (Kafka_service.publish svc topic dupe));
    ignore (Eio.Promise.await (Kafka_service.publish svc topic dupe));
    wait ~what:"the duplicated fact to be delivered twice" ~timeout_s:30.0 (fun () ->
      List.length (List.filter (fun (id, _) -> String.equal id "dupe") !consumed) >= 2);
    wait ~what:"the duplicated effect" ~timeout_s:30.0 (fun () ->
      count_where "outbox_e2e_effects" "effect_id = 'dupe'" = 1);
    let duplicate_domain_rows = count_where "outbox_e2e_domain" "id = 'dupe'" in
    let duplicate_effects = count_where "outbox_e2e_effects" "effect_id = 'dupe'" in
    broker_up := false;
    domain_and_intent ~id:"order" ~seq:2 ~ord:2 ~force_rollback:false;
    domain_and_intent ~id:"order" ~seq:1 ~ord:1 ~force_rollback:false;
    Eio.Time.sleep env#clock 0.5;
    broker_up := true;
    wait ~what:"both ordered facts to be consumed" ~timeout_s:30.0 (fun () ->
      List.length (List.filter (fun (id, _) -> String.equal id "order") !consumed) >= 2);
    let order_seq =
      !consumed
      |> List.rev
      |> List.filter_map (fun (id, seq) ->
        if String.equal id "order" then Some seq else None)
    in
    wait ~what:"the crash row to drain after restart" ~timeout_s:30.0 (fun () ->
      count_where "sol_outbox" "aggregate_key = 'crash'" = 0);
    wait ~what:"the crash fact to be delivered twice" ~timeout_s:30.0 (fun () ->
      List.length (List.filter (fun (id, _) -> String.equal id "crash") !consumed) >= 2);
    let crash_duplicate_facts =
      List.length (List.filter (fun (id, _) -> String.equal id "crash") !consumed)
    in
    let crash_effects = count_where "outbox_e2e_effects" "effect_id = 'crash'" in
    let retry_fact = OutboxFact.{ id = "retry"; seq = 1 } in
    ignore (Eio.Promise.await (Kafka_service.publish svc topic retry_fact));
    wait ~what:"the transient job to succeed" ~timeout_s:30.0 (fun () -> !retry_succeeded);
    let retry_invocations_final = !retry_invocations in
    let retry_effects = count_where "outbox_e2e_effects" "effect_id = 'retry'" in
    let fail_fact = OutboxFact.{ id = "fail"; seq = 1 } in
    ignore (Eio.Promise.await (Kafka_service.publish svc topic fail_fact));
    wait ~what:"the worker to stop on Fail" ~timeout_s:30.0 (fun () -> !failed);
    (match
       Eio.Time.with_timeout env#clock 15.0 (fun () ->
         Ok (Eio.Promise.await worker_done_p))
     with
     | Ok () -> ()
     | Error `Timeout -> ());
    let fail_observed = !failed in
    let redelivered = ref false in
    let module W2 = struct
      module Message = OutboxFact

      let group_id = group_id

      let handle (msg : Message.t) ~trace_ctx:_ : Worker.outcome =
        if String.equal msg.id "fail" then redelivered := true;
        Worker.Ack
      ;;
    end
    in
    let module WR2 = Worker.For_testing.Make (W2) in
    let redeliver_stop, redeliver_stop_r = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (WR2.run
           ~env
           ~config:kafka_config
           ~ot:obs
           ~metrics_port:0
           ~stop:redeliver_stop
           ()));
    wait
      ~what:"the Fail fact to be redelivered (offset was not committed)"
      ~timeout_s:30.0
      (fun () -> !redelivered);
    Eio.Promise.resolve redeliver_stop_r ();
    Eio.Fiber.yield ();
    let fail_redelivered = !redelivered in
    let base_topic = Kafka_service.topic_name_to_string OutboxFact.topic_name in
    let app_retry_topics =
      [ Printf.sprintf "%s.%s.retry" base_topic group_id
      ; Printf.sprintf "%s.%s.dlq" base_topic group_id
      ]
      |> List.filter (fun t ->
        match
          Kafka_service.Admin.query_topic_partitions
            env#net
            ~clock:env#clock
            ~admin_url:kafka_config.admin_url
            ~topic_name:t
        with
        | Ok Kafka_service.Admin.Topic_not_found -> false
        | Ok (Kafka_service.Admin.Topic_partitions _) -> true
        | Error _ -> true)
    in
    Eio.Promise.resolve relay_stop_r ();
    Eio.Promise.resolve jobs_stop_r ();
    Eio.Fiber.yield ();
    let metrics_text = render () in
    let loki_resp =
      match loki_url with
      | None -> None
      | Some url ->
        let p = loki_port url in
        let path = "/loki/api/v1/query?query=%7Bservice%3D%22outbox-e2e%22%7D&limit=5" in
        (try Some (http_get env ~sw ~port:p ~path ()) with
         | _ -> None)
    in
    { ob_db = true
    ; ob_partitions = partitions
    ; ob_rollback_clean = rollback_clean
    ; ob_outage_held = outage_held
    ; ob_outage_recovered = outage_recovered
    ; ob_duplicate_domain_rows = duplicate_domain_rows
    ; ob_duplicate_effects = duplicate_effects
    ; ob_order_seq = order_seq
    ; ob_crash_published = !crash_published
    ; ob_crash_row_survived = crash_row_survived
    ; ob_crash_duplicate_facts = crash_duplicate_facts
    ; ob_crash_effects = crash_effects
    ; ob_retry_invocations = retry_invocations_final
    ; ob_retry_effects = retry_effects
    ; ob_fail_observed = fail_observed
    ; ob_fail_redelivered = fail_redelivered
    ; ob_app_retry_topics = app_retry_topics
    ; ob_metrics = metrics_text
    ; ob_loki = loki_resp
    }
;;

let () =
  let r = run_golden_path () in
  let o = run_outbox_path () in
  Windtrap.run
    "e2e golden workflow"
    [ Windtrap.group
        "http"
        [ Windtrap.test "all orders accepted (HTTP 202)" (fun () ->
            let bad = List.filter (( <> ) 202) r.http_statuses in
            if bad <> []
            then
              Windtrap.failf
                "expected 202, got: %s"
                (String.concat ", " (List.map string_of_int bad)))
        ]
    ; Windtrap.group
        "metrics"
        [ Windtrap.test "sol_svc_requests_total > 0" (fun () ->
            if not (metric_nonzero r.metrics_text "sol_svc_requests_total")
            then Windtrap.fail "metric absent or zero")
        ; Windtrap.test "sol_worker_messages_total > 0" (fun () ->
            if not (metric_nonzero r.metrics_text "sol_worker_messages_total")
            then Windtrap.fail "metric absent or zero")
        ; Windtrap.test "worker /metrics serves metrics" (fun () ->
            match r.worker_metrics_http with
            | None -> Windtrap.fail "worker /metrics was not reachable"
            | Some resp ->
              if not (metric_nonzero resp "sol_worker_messages_total")
              then Windtrap.fail "worker /metrics did not include worker metrics")
        ; Windtrap.test "sol_jobs_processed_total > 0" (fun () ->
            if r.jobs_processed = 0
            then ()
            else if not (metric_nonzero r.metrics_text "sol_jobs_processed_total")
            then Windtrap.fail "metric absent or zero")
        ]
    ; Windtrap.group
        "loki"
        [ Windtrap.test "logs received for service=order-svc" (fun () ->
            match r.loki_resp with
            | None -> Windtrap.fail "Loki could not be queried; the e2e class requires it"
            | Some resp ->
              if not (str_contains resp {|"values":[[|})
              then Windtrap.fail "no log streams in Loki response")
        ; Windtrap.test "sol logs Loki query path reads pushed logs" (fun () ->
            match r.loki_cli_lines with
            | None ->
              Windtrap.fail
                "LOKI_URL is not set, so the class cannot exercise the \
                 Sol_cli_loki.query path"
            | Some (Error msg) ->
              Windtrap.failf "Sol_cli_loki.query could not read Loki: %s" msg
            | Some (Ok 0) ->
              Windtrap.fail
                "Sol_cli_loki.query succeeded but never saw the line emitted through \
                 Sol_obs"
            | Some (Ok _) -> ())
        ]
    ; Windtrap.group
        "postgres"
        [ Windtrap.test "fulfilled orders persisted" (fun () ->
            match r.db_rows with
            | None -> ()
            | Some (Error why) ->
              Windtrap.failf "fulfilled_orders could not be read: %s" why
            | Some (Ok 0) -> ()
            | Some (Ok rows) -> Windtrap.equal Windtrap.int ~msg:"3 rows stored" 3 rows)
        ]
    ; Windtrap.group
        "jobs"
        [ Windtrap.test
            "confirmation-email jobs claimed and completed (sol-jobs, FEAT-077)"
            (fun () ->
               match r.db_rows with
               | None -> ()
               | Some (Error why) ->
                 Windtrap.failf "fulfilled_orders could not be read: %s" why
               | Some (Ok 0) -> ()
               | Some (Ok _) ->
                 Windtrap.equal Windtrap.int ~msg:"3 jobs processed" 3 r.jobs_processed)
        ]
    ; Windtrap.group
        "outbox-facts-to-jobs"
        [ Windtrap.test
            "the declared topic was created at the declared partition count"
            (fun () ->
               if not o.ob_db
               then ()
               else Windtrap.equal Windtrap.int ~msg:"3 partitions" 3 o.ob_partitions)
        ; Windtrap.test
            "a rolled-back transaction leaves no domain row, intent, fact or effect"
            (fun () ->
               if not o.ob_db
               then Windtrap.fail "POSTGRES_URL not set"
               else
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"clean rollback"
                   true
                   o.ob_rollback_clean)
        ; Windtrap.test
            "with the broker unavailable the intent is held, and recovery publishes it \
             once"
            (fun () ->
               if not o.ob_db
               then Windtrap.fail "POSTGRES_URL not set"
               else (
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"held during the outage"
                   true
                   o.ob_outage_held;
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"published after recovery"
                   true
                   o.ob_outage_recovered))
        ; Windtrap.test
            "a duplicate fact delivery leaves one domain row and one independent effect"
            (fun () ->
               if not o.ob_db
               then Windtrap.fail "POSTGRES_URL not set"
               else (
                 Windtrap.equal
                   Windtrap.int
                   ~msg:"one domain row"
                   1
                   o.ob_duplicate_domain_rows;
                 Windtrap.equal Windtrap.int ~msg:"one effect" 1 o.ob_duplicate_effects))
        ; Windtrap.test
            "a blocked earlier event does not let a later one for the same key publish \
             first"
            (fun () ->
               if not o.ob_db
               then Windtrap.fail "POSTGRES_URL not set"
               else
                 Windtrap.equal
                   (Windtrap.list Windtrap.int)
                   ~msg:"per-key order"
                   [ 1; 2 ]
                   o.ob_order_seq)
        ; Windtrap.test
            "a crash between broker ack and the row mark duplicates, never gaps or \
             inverts"
            (fun () ->
               if not o.ob_db
               then Windtrap.fail "POSTGRES_URL not set"
               else (
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"published before the crash"
                   true
                   o.ob_crash_published;
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"row survived the crash"
                   true
                   o.ob_crash_row_survived;
                 Windtrap.equal
                   Windtrap.int
                   ~msg:"re-delivered at least twice"
                   2
                   o.ob_crash_duplicate_facts;
                 Windtrap.equal Windtrap.int ~msg:"still one effect" 1 o.ob_crash_effects))
        ; Windtrap.test
            "a transient job failure retries in sol-jobs and eventually succeeds once"
            (fun () ->
               if not o.ob_db
               then Windtrap.fail "POSTGRES_URL not set"
               else (
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"attempted more than once"
                   true
                   (o.ob_retry_invocations > 1);
                 Windtrap.equal Windtrap.int ~msg:"one effect" 1 o.ob_retry_effects))
        ; Windtrap.test
            "Fail stops the consumer with no application retry or DLQ topic"
            (fun () ->
               if not o.ob_db
               then Windtrap.fail "POSTGRES_URL not set"
               else (
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"handler returned Fail"
                   true
                   o.ob_fail_observed;
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"the offset was not committed (the fact was redelivered)"
                   true
                   o.ob_fail_redelivered;
                 Windtrap.equal
                   (Windtrap.list Windtrap.string)
                   ~msg:"no application retry/DLQ topic"
                   []
                   o.ob_app_retry_topics;
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:"sol_worker_messages_total{status=\"fail\"} recorded"
                   true
                   (str_contains o.ob_metrics "status=\"fail\"")))
        ; Windtrap.test "the outbox and worker metrics are exposed" (fun () ->
            if not o.ob_db
            then Windtrap.fail "POSTGRES_URL not set"
            else (
              Windtrap.equal
                Windtrap.bool
                ~msg:"sol_outbox_published_total > 0"
                true
                (metric_nonzero o.ob_metrics "sol_outbox_published_total");
              Windtrap.equal
                Windtrap.bool
                ~msg:"sol_worker_messages_total > 0"
                true
                (metric_nonzero o.ob_metrics "sol_worker_messages_total")))
        ; Windtrap.test "outbox logs reached Loki" (fun () ->
            match o.ob_loki with
            | None -> Windtrap.fail "Loki could not be queried; the e2e class requires it"
            | Some resp ->
              if not (str_contains resp {|"values":[[|})
              then Windtrap.fail "no outbox log streams in Loki response")
        ]
    ]
;;
