(* Shared runtime behaviour for Sol's service primitives.

   REFAC-043 proposed this extraction; REFAC-081 found it had never landed and
   the primitives still carried independent copies. The first tenant is the
   self-pipe signal handler: the correctness requirements are subtle
   (async-signal-safe write, cloexec, non-blocking write end) and three copies
   meant any fix had to be applied three times.

   BUG-047 / FND-0042: a signal disposition is process-global, but each primitive's
   [run] used to install its own handler. The last one installed won, so in a
   process hosting several primitives the others never saw SIGTERM; and a handler
   outlived the pipe it wrote to, so a later signal wrote into whatever the old fd
   number had become, and a second Ctrl-C was swallowed. Now there is one handler
   per process. Each [install_signal_handler] registers its own self-pipe with it
   and unregisters when its switch ends. *)

let signals = [ Sys.sigterm; Sys.sigint ]

(* Write ends of every live registration. Signal handlers run synchronously on
   the main domain at safe points, so a snapshot taken inside the handler cannot
   race with an unregister that removes an fd before closing it. *)
let registered : Unix.file_descr list Atomic.t = Atomic.make []

(* The dispositions to put back when the last registration goes. *)
let previous : (int * Sys.signal_behavior) list ref = ref []

(* Set by the first signal while registrations exist; a second one means the
   operator wants the process gone, not a second graceful request. *)
let signalled = Atomic.make false
let byte = Bytes.make 1 '\x00'

let handle signum =
  if Atomic.exchange signalled true
  then (
    List.iter (fun s -> Sys.set_signal s Sys.Signal_default) signals;
    Unix.kill (Unix.getpid ()) signum)
  else
    List.iter
      (fun w ->
         try ignore (Unix.single_write w byte 0 1) with
         | Unix.Unix_error _ -> ())
      (Atomic.get registered)
;;

let rec update f =
  let old = Atomic.get registered in
  if not (Atomic.compare_and_set registered old (f old)) then update f
;;

let register w =
  if Atomic.get registered = []
  then (
    Atomic.set signalled false;
    previous := List.map (fun s -> s, Sys.signal s (Sys.Signal_handle handle)) signals);
  update (fun ws -> w :: ws)
;;

let unregister w =
  update (List.filter (fun w' -> w' <> w));
  if Atomic.get registered = []
  then (
    List.iter (fun (s, behavior) -> Sys.set_signal s behavior) !previous;
    previous := [];
    Atomic.set signalled false)
;;

let close_noerr fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let install_signal_handler ~sw resolver =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  register w;
  (* Unregister before closing, so no handler run can see a closed (or reused)
     fd number. *)
  Eio.Switch.on_release sw (fun () ->
    unregister w;
    close_noerr w;
    close_noerr r);
  (* A daemon fiber: the switch cancels it once the body returns, so a service
     that exits for a reason other than a signal does not wait on this fiber
     forever. The consumer checks the resolved promise at a message boundary so
     the in-flight message finishes before shutdown. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio_unix.await_readable r;
    let buf = Bytes.create 1 in
    (try ignore (Unix.read r buf 0 1) with
     | Unix.Unix_error _ -> ());
    ignore (Eio.Promise.try_resolve resolver ());
    `Stop_daemon)
;;
