(* Shared runtime behaviour for Sol's service primitives.

   REFAC-043 proposed this extraction; REFAC-081 found it had never landed and
   the primitives still carried independent copies. The first tenant is the
   self-pipe signal handler: the correctness requirements are subtle
   (async-signal-safe write, cloexec, non-blocking write end) and three copies
   meant any fix had to be applied three times. *)

let install_signal_handler ~sw resolver =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  let handle _ =
    try ignore (Unix.single_write w (Bytes.make 1 '\x00') 0 1) with
    | _ -> ()
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle);
  Sys.set_signal Sys.sigint (Sys.Signal_handle handle);
  (* A daemon fiber: the switch cancels it once the body returns, so a service
     that exits for a reason other than a signal does not wait on this fiber
     forever. The consumer checks the resolved promise at a message boundary so
     the in-flight message finishes before shutdown. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Fun.protect
      ~finally:(fun () ->
        Unix.close r;
        try Unix.close w with
        | _ -> ())
      (fun () ->
         Eio_unix.await_readable r;
         let buf = Bytes.create 1 in
         (try ignore (Unix.read r buf 0 1) with
          | _ -> ());
         (try Eio.Promise.resolve resolver () with
          | _ -> ());
         `Stop_daemon))
;;
