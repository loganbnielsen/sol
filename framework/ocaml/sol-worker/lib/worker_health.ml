(* AUDIT-080: the worker's readiness/liveness observations and its HTTP surface.

   Readiness is the consumer-join state: a Kafka worker is ready only once the
   broker has assigned it partitions, and it stops being ready when a rebalance
   takes them away. Liveness is the poll cadence: a consumer that stops polling
   is stuck even though its process is up, so it must be replaced rather than
   left looking healthy. Both are observations kafka-eio reports
   ([on_assigned]/[on_revoked]/[on_poll]); the policy -- what they mean and when
   they fail -- lives here, in Sol, not in the client.

   Served on the same port as /metrics so the rendered probes need no second
   listener. *)

(* Ten times librdkafka's keepalive poll interval (3s): a consumer that has not
   polled in this long is not merely idle, it is stuck. *)
let liveness_bound_s = 30.0

type t =
  { ready : bool Atomic.t
  ; last_poll : float Atomic.t
  ; now : unit -> float
  }

let create ~now = { ready = Atomic.make false; last_poll = Atomic.make (now ()); now }
let on_assigned t = Atomic.set t.ready true
let on_revoked t = Atomic.set t.ready false
let on_poll t = Atomic.set t.last_poll (t.now ())
let is_ready t = Atomic.get t.ready
let is_live t = t.now () -. Atomic.get t.last_poll <= liveness_bound_s

let respond_string ~status body =
  Cohttp_eio.Server.respond ~status ~body:(Cohttp_eio.Body.of_string body) ()
;;

let serve ~sw ~net ~port t renderer =
  let callback _conn req _body =
    match Cohttp.Request.meth req, Cohttp.Request.resource req with
    | `GET, "/metrics" -> respond_string ~status:`OK (renderer ())
    | `GET, "/readyz" ->
      if is_ready t
      then respond_string ~status:`OK "ready\n"
      else
        respond_string ~status:`Service_unavailable "not ready: no partitions assigned\n"
    | `GET, "/livez" ->
      if is_live t
      then respond_string ~status:`OK "live\n"
      else
        respond_string
          ~status:`Service_unavailable
          "not live: no successful poll recently\n"
    | _ -> respond_string ~status:`Not_found "not found\n"
  in
  let server = Cohttp_eio.Server.make ~callback () in
  (* A worker that cannot bind its health port is not ready, but it must not
     crash: the readiness/liveness probes report the failure, which is the honest
     signal. It also keeps a second worker in the same process from aborting. *)
  try
    let socket =
      Eio.Net.listen
        ~sw
        ~backlog:128
        ~reuse_addr:true
        net
        (`Tcp (Eio.Net.Ipaddr.V4.any, port))
    in
    Cohttp_eio.Server.run
      ~on_error:(fun e ->
        Printf.eprintf "sol-worker: health server error: %s\n%!" (Printexc.to_string e))
      socket
      server
  with
  | e ->
    Printf.eprintf
      "sol-worker: could not serve /metrics,/readyz,/livez on port %d: %s\n%!"
      port
      (Printexc.to_string e);
    `Stop_daemon
;;
