(** Shared capability-row type for Sol's service primitives (-svc, -worker,
    -fn).

    Every primitive's [Make(_).run] takes an [env] naming the I/O capabilities
    it needs and returns [(unit, run_error) result], where [run_error] is that
    primitive's own polymorphic variant (see each primitive's own [run_error]
    type). Any future primitive should match this shape.

    [-worker] and [-fn] both need the exact same capabilities — outbound
    networking, a wall clock, and a monotonic clock for backoff/duration timing
    — hence [timed] below, shared by both. [-svc] needs a different combination
    ([net], [clock], and [fs] for static config/cert loading) and keeps its own
    inline type rather than a shared alias, since nothing else uses that shape.
*)

type ('env, 'net, 'clock, 'mono) timed =
  < net : 'net Eio.Net.t
  ; clock : 'clock Eio.Time.clock
  ; mono_clock : 'mono Eio.Time.Mono.t
  ; .. >
  as
  'env
(** Capabilities [-worker] and [-fn] both need: outbound networking, a wall
    clock, and a monotonic clock. The three extra type parameters exist only
    because OCaml requires object-type aliases to name every type variable
    explicitly (a bare [_] is allowed inline in a function signature but not in
    a standalone [type] declaration) — write [(_, _, _, _) Sol_env.timed] at
    each use site and let inference fill them in, the same as the inline row
    type this replaces. *)
