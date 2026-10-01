open Result.Syntax

type run_error =
  [ `Config of string
  | `Database of string
  ]

let run_error_to_string = function
  | `Config msg -> "sol-outbox: config: " ^ msg
  | `Database msg -> "sol-outbox: database: " ^ msg
;;

type publication =
  { kind : string
  ; key : string
  ; ord : int64
  ; payload : string
  }

let table = "sol_outbox"
let default_poll_interval_s = 0.5
let default_batch = 100
let default_metrics_port = 9090

module Q = struct
  open Caqti_request.Infix
  open Caqti_type

  let insert =
    (t4 string string int64 string ->. unit)
      (Printf.sprintf
         "INSERT INTO %s (kind, aggregate_key, ord, payload) VALUES (?, ?, ?, ?)"
         table)
  ;;

  let table_exists =
    (unit ->? string) (Printf.sprintf "SELECT to_regclass('%s')::text" table)
  ;;

  let oldest_per_key =
    (int ->* t5 int64 int64 string string string)
      (Printf.sprintf
         "SELECT o.id, o.ord, o.aggregate_key, o.kind, o.payload FROM %s o \n\
         \         WHERE o.ord = (SELECT min(i.ord) FROM %s i \n\
         \                        WHERE i.aggregate_key = o.aggregate_key) \n\
         \         ORDER BY o.id LIMIT ?"
         table
         table)
  ;;

  let delete = (int64 ->. unit) (Printf.sprintf "DELETE FROM %s WHERE id = ?" table)

  let pending_by_kind =
    (unit ->* t2 string int)
      (Printf.sprintf "SELECT kind, count(*) FROM %s GROUP BY kind" table)
  ;;

  let oldest_age_by_kind =
    (unit ->* t2 string float)
      (Printf.sprintf
         "SELECT kind, extract(epoch from (now() - min(created_at))) FROM %s GROUP BY \
          kind"
         table)
  ;;

  let pending_list =
    (int ->* t2 string int64)
      (Printf.sprintf
         "SELECT aggregate_key, ord FROM %s ORDER BY aggregate_key, ord LIMIT ?"
         table)
  ;;

  let pending_count = (unit ->! int) (Printf.sprintf "SELECT count(*) FROM %s" table)
end

let publish tx ~key ~ord ~payload ~kind = Pg_db.exec tx Q.insert (kind, key, ord, payload)
let pending pool ?(limit = 1000) () = Pg_db.collect pool Q.pending_list limit

let pending_count pool =
  Pg_db.find pool Q.pending_count () |> Result.map (Option.value ~default:0)
;;

module type EVENT = sig
  type t

  val kind : t -> string
  val kinds : string list
  val encode : t -> string
end

module Make (E : EVENT) = struct
  let publish tx ~key ~ord (event : E.t) =
    let kind = E.kind event in
    if List.mem kind E.kinds
    then publish tx ~key ~ord ~payload:(E.encode event) ~kind
    else
      Error
        (Pg_error.Query_error
           (Printf.sprintf
              "sol-outbox: kind %S is not in E.kinds; the relay would leave it \
               unpublished forever"
              kind))
  ;;

  let report_metrics
        ~pool
        ~(pending_gauge : Obs_eio.gauge_fn option)
        ~(age_gauge : Obs_eio.gauge_fn option)
    =
    (match pending_gauge with
     | None -> ()
     | Some gauge ->
       (match Pg_db.collect pool Q.pending_by_kind () with
        | Error _ -> ()
        | Ok rows ->
          List.iter
            (fun (kind, count) -> gauge ~labels:[ "kind", kind ] (float_of_int count))
            rows));
    match age_gauge with
    | None -> ()
    | Some gauge ->
      (match Pg_db.collect pool Q.oldest_age_by_kind () with
       | Error _ -> ()
       | Ok rows -> List.iter (fun (kind, age) -> gauge ~labels:[ "kind", kind ] age) rows)
  ;;

  let relay
        ~(env : (_, _, _, _) Sol_env.timed)
        ~pool
        ~publish
        ?(poll_interval_s = default_poll_interval_s)
        ?(batch = default_batch)
        ?ot
        ?(metrics_port = default_metrics_port)
        ?(on_ready = fun () -> ())
        ?stop
        ()
    =
    match Pg_db.find pool Q.table_exists () with
    | Error e -> Error (`Database (Pg_error.to_string e))
    | Ok None ->
      Error
        (`Database
            (Printf.sprintf
               "the %s table does not exist; apply the migration that creates it before \
                starting the relay"
               table))
    | Ok (Some _) ->
      if batch < 1
      then Error (`Config "batch must be at least 1")
      else if (not (Float.is_finite poll_interval_s)) || poll_interval_s < 0.0
      then Error (`Config "poll_interval_s must be finite and non-negative")
      else (
        let metrics_renderer = Option.map Sol_obs.metrics_renderer ot in
        let obs = Option.map Sol_obs.obs_eio ot in
        let published, pending_gauge, age_gauge =
          match obs with
          | None -> None, None, None
          | Some o ->
            ( Some
                (Obs_eio.register_counter
                   o
                   ~name:"sol_outbox_published_total"
                   ~help:
                     "Outbox events whose publication was acknowledged, by kind and \
                      outcome"
                   ~label_names:[ "kind"; "status" ])
            , Some
                (Obs_eio.register_gauge
                   o
                   ~name:"sol_outbox_pending"
                   ~help:"Outbox rows waiting to be published, by kind"
                   ~label_names:[ "kind" ])
            , Some
                (Obs_eio.register_gauge
                   o
                   ~name:"sol_outbox_oldest_pending_seconds"
                   ~help:
                     "Age of the oldest unpublished row for a kind: per-key publication \
                      lag"
                   ~label_names:[ "kind" ]) )
        in
        let count (p : publication) status =
          match published with
          | None -> ()
          | Some c -> c ~labels:[ "kind", p.kind; "status", status ] 1
        in
        let warn msg =
          match ot with
          | Some o -> Sol_obs.log_warn o msg
          | None -> Printf.eprintf "sol-outbox: %s\n%!" msg
        in
        let signal_stop, signal_stop_r = Eio.Promise.create () in
        let should_stop () =
          Eio.Promise.is_resolved signal_stop
          ||
          match stop with
          | Some p -> Eio.Promise.is_resolved p
          | None -> false
        in
        let drain () =
          match Pg_db.collect pool Q.oldest_per_key batch with
          | Error e -> Error (`Database (Pg_error.to_string e))
          | Ok rows ->
            List.fold_left
              (fun acc (id, ord, key, kind, payload) ->
                 let* () = acc in
                 let event = { kind; key; ord; payload } in
                 match publish event with
                 | Error msg ->
                   count event "failed";
                   warn
                     (Printf.sprintf
                        "publish failed for kind %s key %s (ord %Ld); leaving it \
                         unpublished and not advancing the key: %s"
                        kind
                        key
                        ord
                        msg);
                   Ok ()
                 | Ok () ->
                   (match Pg_db.exec pool Q.delete id with
                    | Error e ->
                      count event "mark_failed";
                      Error (`Database (Pg_error.to_string e))
                    | Ok () ->
                      count event "ok";
                      Ok ()))
              (Ok ())
              rows
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
          on_ready ();
          let rec loop () =
            if should_stop ()
            then Ok ()
            else
              let* () = drain () in
              report_metrics ~pool ~pending_gauge ~age_gauge;
              if should_stop ()
              then Ok ()
              else (
                Eio.Time.sleep env#clock poll_interval_s;
                loop ())
          in
          loop ()))
  ;;
end

module For_testing = struct
  let pending = pending
  let pending_count = pending_count
end
