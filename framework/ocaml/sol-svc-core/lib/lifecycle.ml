type phase =
  | Serving
  | Unready
  | Draining

type state =
  { phase : phase
  ; in_flight : int
  }

type t = state Atomic.t
type request = t

let create () = Atomic.make { phase = Serving; in_flight = 0 }
let ready t = (Atomic.get t).phase = Serving

let rec update t f =
  let old = Atomic.get t in
  let next = f old in
  if not (Atomic.compare_and_set t old next) then update t f
;;

let begin_shutdown t = update t (fun s -> { s with phase = Unready })
let begin_draining t = update t (fun s -> { s with phase = Draining })

let begin_request t =
  let rec acquire () =
    let old = Atomic.get t in
    if old.phase = Draining
    then None
    else if Atomic.compare_and_set t old { old with in_flight = old.in_flight + 1 }
    then Some t
    else acquire ()
  in
  acquire ()
;;

let finish_request t = update t (fun s -> { s with in_flight = max 0 (s.in_flight - 1) })
let in_flight t = (Atomic.get t).in_flight
