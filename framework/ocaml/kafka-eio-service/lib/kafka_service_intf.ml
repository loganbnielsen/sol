type topic_name = string

(* Validation itself lives in kafka-eio, which this package builds directly
   on -- Kafka topic naming syntax is kafka-eio's contract to own, not
   something to reimplement here. See Kafka.Topic_name. *)
let topic_name name =
  Kafka.Topic_name.of_string name |> Result.map Kafka.Topic_name.to_string
;;

let topic_name_exn name =
  match topic_name name with
  | Ok topic -> topic
  | Error e ->
    invalid_arg ("invalid Kafka topic name " ^ Printf.sprintf "%S" name ^ ": " ^ e)
;;

let topic_name_to_string topic = topic

module type MESSAGE = sig
  type t

  val topic_name : topic_name
  val schema : string
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

type 'a topic =
  { name : topic_name
  ; schema_id : int
  ; encode : 'a -> Yojson.Safe.t
  ; decode : Yojson.Safe.t -> ('a, string) result
  }

type topic_durability =
  | Broker_default
  | Single_broker_loss

type config =
  { brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; linger_ms : int
  ; partitions : int
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type t =
  { producer : Kafka.Producer.t
  ; brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; partitions : int
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type consume_partitioned_error =
  | Consumer_error of Kafka.Error.t
  | Partition_errors of (int32 * Kafka.Error.t) list

type handler_error =
  | Retry
  | Dead_letter of string
  | Kafka_error of Kafka.Error.t

type decode_error_policy =
  | Route_to_dlq
  | Ack_and_drop

let ensure_topic producer ~topic_name ~partitions ~topic_durability =
  let replication_factor =
    match topic_durability with
    | Broker_default -> 1
    | Single_broker_loss -> 3
  in
  match
    Kafka.Producer.create_topic producer ~topic_name ~partitions ~replication_factor
  with
  | Ok () -> Ok ()
  | Error e -> Error e
;;

type topic_partition_metadata =
  | Topic_not_found
  | Topic_partitions of
      { partitions : int
      ; replication_factor : int
      }

let topic_has_required_replication topic_durability = function
  | Topic_not_found -> true
  | Topic_partitions { replication_factor; _ } ->
    (match topic_durability with
     | Broker_default -> true
     | Single_broker_loss -> replication_factor >= 3)
;;

type topic_partition_error =
  | Topic_admin_request_failed of string
  | Topic_admin_unexpected_status of int * string
  | Topic_admin_malformed_response of string

let topic_partition_error_to_string = function
  | Topic_admin_request_failed e -> "admin API request failed: " ^ e
  | Topic_admin_unexpected_status (status, body) ->
    Printf.sprintf "admin API HTTP %d: %s" status body
  | Topic_admin_malformed_response body -> "malformed admin API topic response: " ^ body
;;

let decode_topic_partitions body =
  try
    match Yojson.Safe.from_string body with
    | `List (_ :: _ as parts) ->
      let replicas =
        List.map
          (function
            | `Assoc fields ->
              (match List.assoc_opt "replicas" fields with
               | Some (`List replicas) -> List.length replicas
               | _ -> raise Exit)
            | _ -> raise Exit)
          parts
      in
      Ok
        (Topic_partitions
           { partitions = List.length parts
           ; replication_factor = List.fold_left min max_int replicas
           })
    | _ -> Error (Topic_admin_malformed_response body)
  with
  | Yojson.Json_error _ | Exit -> Error (Topic_admin_malformed_response body)
;;

let query_topic_partitions net ~clock ~admin_url ~topic_name =
  match
    Kafka_service_http.http_get
      net
      ~clock
      ~base_url:admin_url
      ~path:(Printf.sprintf "/v1/partitions/kafka/%s" topic_name)
  with
  | Error e -> Error (Topic_admin_request_failed e)
  | Ok (404, _) -> Ok Topic_not_found
  | Ok (200, body) -> decode_topic_partitions body
  | Ok (status, body) -> Error (Topic_admin_unexpected_status (status, body))
;;

(* Counts and logs one source-topic decode failure. [disposition] says what
   happens to the record next -- BUG-051: under Retry_topics it is dead-lettered,
   not dropped, so the log line must not claim it was skipped. *)
let observe_decode_error ~ot ~topic_name =
  let decode_err_count =
    match ot with
    | None -> None
    | Some o ->
      Some
        (Obs_eio.register_counter
           o
           ~name:"sol_worker_decode_errors_total"
           ~help:
             "Total source-topic Kafka messages that failed to decode (dead-lettered or \
              acked-and-dropped, per the decode_error_policy)"
           ~label_names:[])
  in
  fun e ~raw_bytes ~disposition ->
    (match decode_err_count with
     | Some c -> c 1
     | None -> ());
    match ot with
    | None -> ()
    | Some o ->
      Obs_eio.log_standalone
        o
        Obs_eio.Error
        ~fields:
          [ "error", e
          ; ( "raw_bytes_len"
            , string_of_int (Option.fold ~none:0 ~some:Bytes.length raw_bytes) )
          ; "topic", topic_name
          ]
        (match disposition with
         | `Dropped -> "sol-worker: decode error, skipping message"
         | `Dead_lettered -> "sol-worker: decode error, routing message to the DLQ")
;;

let wrap_on_decode_error ~ot ~topic_name user_on_decode_error =
  let observe = observe_decode_error ~ot ~topic_name in
  fun e ~raw_bytes ~ack ->
    observe e ~raw_bytes ~disposition:`Dropped;
    user_on_decode_error e ~raw_bytes ~ack
;;

(* The explicit ack-and-drop disposition: log, ack, continue. *)
let ack_and_drop_decode_error e ~raw_bytes:_ ~ack =
  Printf.eprintf "sol-worker: DECODE_ERROR skip=true error=%S\n%!" e;
  ignore (ack ());
  Kafka.Consumer.Continue
;;
