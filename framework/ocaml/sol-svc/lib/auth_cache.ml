type entry =
  { url : string
  ; fetched_at : float
  ; jwks : Jose.Jwks.t
  }

let cache : entry option Atomic.t = Atomic.make None
let failure : (string * float * string) option Atomic.t = Atomic.make None
let ttl_s = 300.0
let unknown_kid_refetch_interval_s = 30.0
let failure_backoff_s = 5.0
let peek () = Atomic.get cache
let replace entry = Atomic.set cache (Some entry)
let clear () = Atomic.set cache None
let last_failure () = Atomic.get failure
let set_last_failure f = Atomic.set failure f
