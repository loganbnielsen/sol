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

type retry_strategy = Kafka_service.retry_strategy =
  | In_memory of retry_policy
  | Retry_topics of retry_policy

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

(* ── Signal handling ────────────────────────────────────────────────────── *)

(* The self-pipe handler lives in [Sol_runtime] (REFAC-081): the worker, the
   service and the function all need the same shutdown contract, and the
   handler's correctness is subtle enough that one copy is safer than three. *)

(* ── Shared runtime harness ─────────────────────────────────────────────── *)

let default_metrics_port = 9090

(* Metrics registration, signal handling, and stop/max_messages bookkeeping
   are identical between the Ack-only and retry-capable tiers -- only the
   per-message handler wrapping (what W.handle can return, which
   Kafka_service entry point to call) differs. [body] receives everything a
   tier needs to build and run its own handler/consume-loop. *)
let with_runtime
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
  (* Checked before processing each message: an external/signal stop request,
     or max_messages already reached by an earlier message. *)
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
  Eio.Switch.run (fun sw ->
    Sol_runtime.install_signal_handler ~sw signal_stop_r;
    Option.iter
      (fun render ->
         Obs_prometheus.serve
           ~sw
           ~net:env#net
           (`Tcp (Eio.Net.Ipaddr.V4.any, metrics_port))
           render)
      metrics_renderer;
    body ~sw ~ot ~msg_count ~msg_duration ~should_stop ~advance)
;;

(* Ack after the handler succeeds, so a side effect is never acked before it
   happens. An ack failure is a commit failure, not a processing failure --
   retrying would risk a duplicate -- so it's only escalated to
   Kafka.Consumer.Error when fatal. Shared by both tiers: this branch never
   depends on what W.handle returned, only on whether ack() itself
   succeeded. [wrap_fatal] lets each tier's handler_error type stay its own
   -- plain [Kafka.Error.t] for the Ack-only tier ([Kafka_service.consume]'s
   handler type), [Kafka_service.handler_error] for the retryable tier
   ([consume_partitioned]'s). *)
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

(* ── Ack-only tier ───────────────────────────────────────────────────────── *)

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
        ~body:(fun ~sw ~ot ~msg_count ~msg_duration ~should_stop ~advance ->
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
          let ( let* ) = Result.bind in
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
            Kafka_service.consume
              svc
              topic
              ~group_id:W.group_id
              ~sw
              ~clock:env#clock
              ?on_ready
              ?ot
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

(* ── Retry-capable tier ─────────────────────────────────────────────────── *)

module Make_with_retry_and_test_seam (W : RETRYABLE_WORKER) = struct
  let run
        ~(env : (_, _, _, _) Sol_env.timed)
        ~config
        ~retry_strategy
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
        ~body:(fun ~sw ~ot ~msg_count ~msg_duration ~should_stop ~advance ->
          let on_retry ~partition:_ ~attempt:_ ~delay_s:_ =
            match msg_count with
            | Some c -> c ~labels:[ "status", "retry" ] 1
            | None -> ()
          in
          (* BUG-029: distinct from on_retry (fires once per record when a
             retry is *scheduled*, before publication is attempted) -- this
             fires once the relay's own publish to the retry/DLQ topic
             resolves, so "retry" in sol_worker_messages_total no longer
             conflates "we decided to retry" with "the retry was actually
             durably published". *)
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
          let ( let* ) = Result.bind in
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
              Kafka_service.consume_partitioned
                svc
                topic
                ~group_id:W.group_id
                ~sw
                ~clock:env#clock
                ?on_ready
                ~retry_strategy
                ~on_retry
                ~on_relay_publish
                ?ot
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

  let run ~env ~config ~retry_strategy ?ot ?metrics_port ?on_ready ?stop ?max_messages () =
    Impl.run
      ~env
      ~config
      ~retry_strategy
      ?ot
      ?metrics_port
      ?on_ready
      ?stop
      ?max_messages
      ()
  ;;
end

module For_testing = struct
  module Make = Make_with_test_seam
  module Make_with_retry = Make_with_retry_and_test_seam
end
