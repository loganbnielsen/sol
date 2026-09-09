type trigger = Cron of string | Lambda
type run_error = [ `Config of string | `Run of string | `Signalled ]

let run_error_to_string = function
  | `Config msg -> "sol-fn: config error: " ^ msg
  | `Run msg -> "sol-fn: run failed: " ^ msg
  | `Signalled -> "sol-fn: interrupted by signal"

module type FN = sig
  val trigger : trigger
  val run : unit -> (unit, string) result
end

(* ── Signal handling ────────────────────────────────────────────────────── *)

(* Self-pipe trick: signal handler writes one byte to a non-blocking pipe;
   an Eio fiber awaits the read end and resolves the stop promise. *)
let install_signal_handler ~sw resolver =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  let handle _ =
    try ignore (Unix.single_write w (Bytes.make 1 '\x00') 0 1) with _ -> ()
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle);
  Sys.set_signal Sys.sigint (Sys.Signal_handle handle);
  (* Daemon fiber: the switch cancels it once the body returns normally. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Fun.protect
        ~finally:(fun () ->
          Unix.close r;
          try Unix.close w with _ -> ())
        (fun () ->
          Eio_unix.await_readable r;
          let buf = Bytes.create 1 in
          (try ignore (Unix.read r buf 0 1) with _ -> ());
          (try Eio.Promise.resolve resolver () with _ -> ());
          `Stop_daemon))

(* ── Make functor ───────────────────────────────────────────────────────── *)

module Make (F : FN) = struct
  let default_job = function Cron sched -> sched | Lambda -> "lambda"

  let run ~(env : (_, _, _, _) Sol_env.timed) ?pushgateway_url ?job ?ot ?stop ()
      =
    let job = Option.value job ~default:(default_job F.trigger) in
    let backend, renderer =
      match ot with
      | Some o -> Sol_obs.backend_and_renderer o
      | None -> Obs_prometheus.create ()
    in
    let ot =
      Obs_eio.create ~service:job ~mono_clock:env#mono_clock ~backend ()
    in
    let invocations, duration_h =
      Obs_eio.register_counter_and_histogram ot
        ~counter_name:"sol_fn_invocations_total"
        ~counter_help:"Total function invocations by status"
        ~counter_labels:[ "status" ] ~histogram_name:"sol_fn_duration_seconds"
        ~histogram_help:"Function run duration in seconds" ~histogram_labels:[]
    in
    (* Push errors are always swallowed — push never blocks exit (Cron) or
       the next loop iteration (Lambda). *)
    let push_metrics url =
      (* Obs_prometheus.push already re-raises Eio.Cancel.Cancelled and fatal
         exceptions, and converts everything else to Error; no need to
         duplicate that here. *)
      match
        Obs_prometheus.push ~net:env#net ~clock:env#clock ~url ~job renderer
      with
      | Ok () -> ()
      | Error e ->
          Obs_eio.log_standalone ot Obs_eio.Warn
            ~fields:[ ("error", Obs_prometheus.push_error_to_string e) ]
            "sol-fn: push failed; continuing"
    in
    let record_and_push ~t0 outcome =
      let dt = Eio.Time.now env#clock -. t0 in
      duration_h dt;
      (match outcome with
      | `Completed (Ok ()) -> invocations ~labels:[ ("status", "ok") ] 1
      | `Completed (Error _) -> invocations ~labels:[ ("status", "error") ] 1
      | `Signalled -> invocations ~labels:[ ("status", "cancelled") ] 1);
      Option.iter push_metrics pushgateway_url
    in
    let run_body () =
      try F.run () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    match F.trigger with
    | Cron _ -> (
        let signal_stop, signal_stop_r = Eio.Promise.create () in
        let await_stop () =
          match stop with
          | None -> Eio.Promise.await signal_stop
          | Some external_stop ->
              Eio.Fiber.first
                (fun () -> Eio.Promise.await signal_stop)
                (fun () -> Eio.Promise.await external_stop)
        in
        let t0 = Eio.Time.now env#clock in
        let outcome =
          match stop with
          | Some external_stop when Eio.Promise.is_resolved external_stop ->
              `Signalled
          | _ ->
              Eio.Switch.run (fun sw ->
                  install_signal_handler ~sw signal_stop_r;
                  Eio.Fiber.first
                    (fun () -> `Completed (run_body ()))
                    (fun () ->
                      await_stop ();
                      `Signalled))
        in
        record_and_push ~t0 outcome;
        match outcome with
        | `Completed (Ok ()) -> Ok ()
        | `Completed (Error msg) -> Error (`Run msg)
        | `Signalled -> Error `Signalled)
    | Lambda -> (
        match Lambda_runtime.runtime_api_base () with
        | Error err -> Error (`Config (Lambda_runtime.error_to_string err))
        | Ok base ->
            let signal_stop, signal_stop_r = Eio.Promise.create () in
            let await_stop () =
              match stop with
              | None -> Eio.Promise.await signal_stop
              | Some external_stop ->
                  Eio.Fiber.first
                    (fun () -> Eio.Promise.await signal_stop)
                    (fun () -> Eio.Promise.await external_stop)
            in
            let result =
              Eio.Switch.run (fun sw ->
                  install_signal_handler ~sw signal_stop_r;
                  let runtime = Lambda_runtime.create ~net:env#net ~base in
                  Eio.Fiber.first
                    (fun () ->
                      Lambda_runtime.run_loop runtime ~clock:env#clock
                        ~on_error:(fun msg ->
                          Obs_eio.log_standalone ot Obs_eio.Error
                            ~fields:[ ("error", msg) ]
                            "sol-fn: lambda-eio runtime loop error")
                        ~handler:(fun (_ : Lambda_runtime.invocation) ->
                          let t0 = Eio.Time.now env#clock in
                          let result = run_body () in
                          record_and_push ~t0 (`Completed result);
                          match result with
                          | Ok () -> Ok {|{"status":"ok"}|}
                          | Error msg -> Error msg)
                        ();
                      Ok ())
                    (fun () ->
                      await_stop ();
                      Ok ()))
            in
            (* Fiber.first discards the losing fiber's Cancelled internally, so when
           stop resolves first this Switch.run completes normally — it ends the
           loop, not the process. *)
            result)
end
