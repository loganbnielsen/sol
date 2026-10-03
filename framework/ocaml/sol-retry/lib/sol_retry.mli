type policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

val default_policy : policy
val validate : policy -> (unit, string) result
val backoff_s : rng:Random.State.t -> policy -> attempt:int -> float

type t

val of_policy : policy -> (t, string) result

val run
  :  clock:_ Eio.Time.clock
  -> ?rng:Random.State.t
  -> t
  -> (unit -> ('a, 'e) result)
  -> ('a, 'e) result
