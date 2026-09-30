type outcome =
  | Ack
  | Retry of string
  | Dead_letter of string

type ack_outcome = Ack

module type WORKER = sig
  module Message : Kafka_service.MESSAGE

  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> ack_outcome
end

module type RETRYABLE_WORKER = sig
  module Message : Kafka_service.MESSAGE

  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> outcome
end

type retry_policy = Kafka.Consumer.retry_policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

let default_retry_policy : retry_policy =
  { base_delay_s = 1.0; max_delay_s = 600.0; max_attempts = 5; jitter_ratio = 0.1 }
;;

type decode_error_policy = Kafka_service.decode_error_policy =
  | Route_to_dlq
  | Ack_and_drop

type run_error =
  [ `Create of Kafka_service.error
  | `Register of Kafka_service.error
  | `Consume of Kafka_service.consume_partitioned_error
  ]

let consume_error_to_string = function
  | Kafka_service.Consumer_error ke -> Kafka.Error.to_string ke
  | Kafka_service.Partition_errors errs ->
    errs
    |> List.map (fun (p, e) ->
      Printf.sprintf "partition %ld: %s" p (Kafka.Error.to_string e))
    |> String.concat "; "
;;

let run_error_to_string = function
  | `Create e -> "sol-worker: create failed: " ^ Kafka_service.error_to_string e
  | `Register e -> "sol-worker: register failed: " ^ Kafka_service.error_to_string e
  | `Consume e ->
    (match e with
     | Kafka_service.Consumer_error _ ->
       "sol-worker: consume error: " ^ consume_error_to_string e
     | Kafka_service.Partition_errors errs ->
       "sol-worker: consume error ("
       ^ string_of_int (List.length errs)
       ^ " partition(s)): "
       ^ consume_error_to_string e)
;;

let default_metrics_port = 9090

let join_stop ~sw ?signal ?caller () =
  let handle, handle_r = Eio.Promise.create () in
  let resolve_once () =
    if not (Eio.Promise.is_resolved handle) then Eio.Promise.resolve handle_r ()
  in
  let watch p =
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Promise.await p;
      resolve_once ();
      `Stop_daemon)
  in
  Option.iter watch signal;
  Option.iter watch caller;
  handle
;;

let with_runtime_unflushed
      ~(env : (_, _, _, _) Sol_env.timed)
      ~ot
      ~metrics_port
      ~stop
      ~max_messages
      ~body
  =
  let metrics_renderer = Option.map Sol_obs.metrics_renderer ot in
  let ot = Option.map Sol_obs.obs_eio ot in
  let msg_count, msg_duration =
    match ot with
    | None -> None, None
    | Some o ->
      let c, h =
        Obs_eio.register_counter_and_histogram
          o
          ~counter_name:"sol_worker_messages_total"
          ~counter_help:"Total messages processed by status"
          ~counter_labels:[ "status" ]
          ~histogram_name:"sol_worker_message_duration_seconds"
          ~histogram_help:"Message processing latency in seconds"
          ~histogram_labels:[]
      in
      Some c, Some h
  in
  let signal_stop, signal_stop_r = Eio.Promise.create () in
  let remaining =
    match max_messages with
    | Some n -> Some (ref n)
    | None -> None
  in
  let should_stop () =
    Eio.Promise.is_resolved signal_stop
    || (match stop with
        | Some p -> Eio.Promise.is_resolved p
        | None -> false)
    ||
    match remaining with
    | Some r -> !r <= 0
    | None -> false
  in
  let advance () =
    match remaining with
    | None -> Kafka.Consumer.Continue
    | Some r ->
      decr r;
      if !r <= 0 then Kafka.Consumer.Stop else Kafka.Consumer.Continue
  in
  let stop_handle ~sw = join_stop ~sw ~signal:signal_stop ?caller:stop () in
  let health = Worker_health.create ~now:(fun () -> Eio.Time.now env#clock) in
  Eio.Switch.run (fun sw ->
    Sol_runtime.install_signal_handler ~sw signal_stop_r;
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Worker_health.serve ~sw ~net:env#net ~port:metrics_port health (fun () ->
        match metrics_renderer with
        | Some render -> render ()
        | None -> ""));
    body
      ~sw
      ~ot
      ~msg_count
      ~msg_duration
      ~should_stop
      ~advance
      ~health
      ~stop_handle:(stop_handle ~sw))
;;

let with_runtime ~env ~ot ~metrics_port ~stop ~max_messages ~body =
  let result = with_runtime_unflushed ~env ~ot ~metrics_port ~stop ~max_messages ~body in
  Option.iter (fun o -> Sol_obs.flush o) ot;
  result
;;

let handle_ack
      ~env
      ~ot
      ~(msg_count : Obs_eio.counter_fn option)
      ~(msg_duration : Obs_eio.histogram_fn option)
      ~t0
      ~advance
      ~wrap_fatal
      ~ack
  =
  let dt = Eio.Time.now env#clock -. t0 in
  (match msg_duration with
   | Some h -> h dt
   | None -> ());
  match ack () with
  | Ok () ->
    (match msg_count with
     | Some c -> c ~labels:[ "status", "ok" ] 1
     | None -> ());
    advance ()
  | Error e ->
    (match msg_count with
     | Some c -> c ~labels:[ "status", "ack_failed" ] 1
     | None -> ());
    (match ot with
     | None -> ()
     | Some o ->
       Obs_eio.log_standalone
         o
         (if Kafka.Error.is_fatal e then Obs_eio.Error else Obs_eio.Warn)
         ~fields:[ "error", Kafka.Error.to_string e ]
         (if Kafka.Error.is_fatal e
          then "sol-worker: fatal ack failure, stopping consumer"
          else
            "sol-worker: ack failed, offset not committed; message eligible for \
             redelivery"));
    if Kafka.Error.is_fatal e then Kafka.Consumer.Error (wrap_fatal e) else advance ()
;;

let log_partition_errors ~ot result =
  match result, ot with
  | Error (`Consume (Kafka_service.Partition_errors errs)), Some o ->
    List.iter
      (fun (partition, e) ->
         Obs_eio.log_standalone
           o
           Obs_eio.Error
           ~fields:
             [ "partition", Int32.to_string partition; "error", Kafka.Error.to_string e ]
           "sol-worker: partition exhausted its retry budget")
      errs
  | _ -> ()
;;

module Make_with_test_seam (W : WORKER) = struct
  let run
        ~(env : (_, _, _, _) Sol_env.timed)
        ~config
        ?ot
        ?(metrics_port = default_metrics_port)
        ?on_ready
        ?stop
        ?max_messages
        ?test_consume_loop
        ()
    =
    let result =
      with_runtime
        ~env
        ~ot
        ~metrics_port
        ~stop
        ~max_messages
        ~body:
          (fun
            ~sw ~ot ~msg_count ~msg_duration ~should_stop ~advance ~health ~stop_handle ->
          let handler msg ~ack ~trace_ctx =
            if should_stop ()
            then Kafka.Consumer.Stop
            else (
              let t0 = Eio.Time.now env#clock in
              match W.handle msg ~trace_ctx with
              | Ack ->
                handle_ack
                  ~env
                  ~ot
                  ~msg_count
                  ~msg_duration
                  ~t0
                  ~advance
                  ~wrap_fatal:(fun e -> e)
                  ~ack)
          in
          let open Result.Syntax in
          match test_consume_loop with
          | Some f ->
            f ~handler ();
            Ok ()
          | None ->
            let* svc =
              Kafka_service.create config ~sw |> Result.map_error (fun msg -> `Create msg)
            in
            let* topic =
              Kafka_service.register svc ~net:env#net ~clock:env#clock (module W.Message)
              |> Result.map_error (fun msg -> `Register msg)
            in
            let hooks : Kafka_service.consumer_hooks =
              { Kafka_service.no_hooks with
                kafka =
                  { Kafka.Consumer.default_hooks with
                    on_ready = Option.value on_ready ~default:ignore
                  ; on_assigned = (fun () -> Worker_health.on_assigned health)
                  ; on_revoked = (fun () -> Worker_health.on_revoked health)
                  ; on_poll = (fun () -> Worker_health.on_poll health)
                  }
              }
            in
            Kafka_service.consume
              svc
              topic
              ~group_id:W.group_id
              ~sw
              ~clock:env#clock
              ~hooks
              ?ot
              ~stop:stop_handle
              ~handler
              ()
            |> Result.map_error (fun e -> `Consume (Kafka_service.Consumer_error e)))
    in
    result
  ;;
end

module Make (W : WORKER) = struct
  module Impl = Make_with_test_seam (W)

  let run ~env ~config ?ot ?metrics_port ?on_ready ?stop ?max_messages () =
    Impl.run ~env ~config ?ot ?metrics_port ?on_ready ?stop ?max_messages ()
  ;;
end

module Make_with_retry_and_test_seam (W : RETRYABLE_WORKER) = struct
  let run
        ~(env : (_, _, _, _) Sol_env.timed)
        ~config
        ?(retry_policy = default_retry_policy)
        ?decode_error_policy
        ?ot
        ?(metrics_port = default_metrics_port)
        ?on_ready
        ?stop
        ?max_messages
        ?test_consume_loop
        ()
    =
    let result =
      with_runtime
        ~env
        ~ot
        ~metrics_port
        ~stop
        ~max_messages
        ~body:
          (fun
            ~sw ~ot ~msg_count ~msg_duration ~should_stop ~advance ~health ~stop_handle ->
          let on_retry ~partition:_ ~attempt:_ ~delay_s:_ =
            match msg_count with
            | Some c -> c ~labels:[ "status", "retry" ] 1
            | None -> ()
          in
          let on_relay_publish ~partition:_ ~attempt:_ ~outcome =
            match msg_count with
            | None -> ()
            | Some c ->
              (match outcome with
               | `Published -> c ~labels:[ "status", "relay_published" ] 1
               | `Failed -> c ~labels:[ "status", "relay_failed" ] 1)
          in
          let handler msg ~ack ~trace_ctx =
            if should_stop ()
            then Kafka.Consumer.Stop
            else (
              let t0 = Eio.Time.now env#clock in
              match W.handle msg ~trace_ctx with
              | Retry _ ->
                (match msg_count with
                 | Some c -> c ~labels:[ "status", "error" ] 1
                 | None -> ());
                Kafka.Consumer.Error Kafka_service.Retry
              | Dead_letter reason ->
                (match msg_count with
                 | Some c -> c ~labels:[ "status", "dead_letter" ] 1
                 | None -> ());
                Kafka.Consumer.Error (Kafka_service.Dead_letter reason)
              | Ack ->
                handle_ack
                  ~env
                  ~ot
                  ~msg_count
                  ~msg_duration
                  ~t0
                  ~advance
                  ~wrap_fatal:(fun e -> Kafka_service.Kafka_error e)
                  ~ack)
          in
          let open Result.Syntax in
          match test_consume_loop with
          | Some f ->
            f ~handler ();
            Ok ()
          | None ->
            let* svc =
              Kafka_service.create config ~sw |> Result.map_error (fun msg -> `Create msg)
            in
            let* topic =
              Kafka_service.register svc ~net:env#net ~clock:env#clock (module W.Message)
              |> Result.map_error (fun msg -> `Register msg)
            in
            let result =
              let hooks : Kafka_service.consumer_hooks =
                { kafka =
                    { Kafka.Consumer.default_hooks with
                      on_ready = Option.value on_ready ~default:ignore
                    ; on_assigned = (fun () -> Worker_health.on_assigned health)
                    ; on_revoked = (fun () -> Worker_health.on_revoked health)
                    ; on_poll = (fun () -> Worker_health.on_poll health)
                    ; on_retry
                    }
                ; on_relay_publish
                }
              in
              Kafka_service.consume_partitioned
                svc
                topic
                ~group_id:W.group_id
                ~sw
                ~net:env#net
                ~clock:env#clock
                ~hooks
                ?decode_error_policy
                ~retry_policy
                ?ot
                ~stop:stop_handle
                ~handler
                ()
              |> Result.map_error (fun ke -> `Consume ke)
            in
            log_partition_errors ~ot result;
            result)
    in
    result
  ;;
end

module Make_with_retry (W : RETRYABLE_WORKER) = struct
  module Impl = Make_with_retry_and_test_seam (W)

  let run
        ~env
        ~config
        ?retry_policy
        ?decode_error_policy
        ?ot
        ?metrics_port
        ?on_ready
        ?stop
        ?max_messages
        ()
    =
    Impl.run
      ~env
      ~config
      ?retry_policy
      ?decode_error_policy
      ?ot
      ?metrics_port
      ?on_ready
      ?stop
      ?max_messages
      ()
  ;;
end

module For_testing = struct
  let join_stop = join_stop

  module Make = Make_with_test_seam
  module Make_with_retry = Make_with_retry_and_test_seam
end
