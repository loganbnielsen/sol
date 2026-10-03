type policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

let default_policy =
  { base_delay_s = 1.0; max_delay_s = 600.0; max_attempts = 5; jitter_ratio = 0.1 }
;;

let validate (policy : policy) =
  let non_negative_finite name value =
    if Float.is_finite value && value >= 0.0
    then Ok ()
    else
      Error
        (Printf.sprintf
           "%s must be a finite number >= 0 (got %s)"
           name
           (Float.to_string value))
  in
  if policy.max_attempts = 0
  then Error "max_attempts must be nonzero (negative = unlimited)"
  else (
    match non_negative_finite "base_delay_s" policy.base_delay_s with
    | Error _ as error -> error
    | Ok () ->
      (match non_negative_finite "max_delay_s" policy.max_delay_s with
       | Error _ as error -> error
       | Ok () ->
         if
           Float.is_finite policy.jitter_ratio
           && policy.jitter_ratio >= 0.0
           && policy.jitter_ratio <= 1.0
         then Ok ()
         else
           Error
             (Printf.sprintf
                "jitter_ratio must be a finite number within [0, 1] (got %s)"
                (Float.to_string policy.jitter_ratio))))
;;

let backoff_s ~rng policy ~attempt =
  let raw = policy.base_delay_s *. (2. ** Float.of_int (attempt - 1)) in
  if policy.jitter_ratio <= 0.0
  then Float.min policy.max_delay_s (Float.max 0.0 raw)
  else (
    let jitter_unit = Random.State.float rng (2.0 *. policy.jitter_ratio) in
    let jittered = raw *. (1.0 +. (jitter_unit -. policy.jitter_ratio)) in
    Float.min policy.max_delay_s (Float.max 0.0 jittered))
;;

type t = { policy : policy }

let of_policy policy = Result.map (fun () -> { policy }) (validate policy)
let default_rng = Random.State.make_self_init ()
let default_rng_mutex = Mutex.create ()

let draw_default policy ~attempt =
  Mutex.lock default_rng_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock default_rng_mutex)
    (fun () -> backoff_s ~rng:default_rng policy ~attempt)
;;

let run ~clock ?rng ({ policy } : t) operation =
  let draw =
    match rng with
    | Some rng -> fun ~attempt -> backoff_s ~rng policy ~attempt
    | None -> fun ~attempt -> draw_default policy ~attempt
  in
  let rec attempt n =
    match operation () with
    | Ok _ as succeeded -> succeeded
    | Error _ as exhausted ->
      if policy.max_attempts >= 0 && n >= policy.max_attempts
      then exhausted
      else (
        Eio.Time.sleep clock (draw ~attempt:n);
        attempt (n + 1))
  in
  attempt 1
;;
