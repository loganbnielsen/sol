(* BUG-032: the name of one manually-triggered run of a scheduled workload.

   `sol fn run` creates a Job from the workload's CronJob. The name used to be
   `<k8s_name>-manual-<epoch seconds>`, and the comment that justified it held that
   one second of resolution was enough because "a manual run is a human typing a
   command, not a high-frequency automated path". That premise lasted until someone
   fired several invocations at once to generate burst load: they landed in the same
   second, produced the same name, and every one after the first failed with
   AlreadyExists.

   So the epoch-seconds part stays (it keeps the name readable and roughly ordered)
   but uniqueness comes from minted entropy, exactly as
   {!Sol_cli_deployment_id} guarantees that two independent actors deploying in the
   same second do not collide. The entropy source is that module's rather than a
   second copy: it is the same requirement, and one definition of "OS entropy where
   available, with a fallback" is enough for both.

   The result is bounded to 63 characters because Kubernetes derives the pod's
   `job-name` label from the Job's name and a label value is capped there. The *base*
   is shortened to make room rather than the suffix truncated — truncating would cut
   the entropy off the end and bring the collision straight back. *)

(* Kubernetes' cap for a label value, and so for any Job name the controller copies
   into one. *)
let max_length = 63

let entropy_hex (entropy : string) : string =
  String.sub (Digest.to_hex (Digest.string entropy)) 0 8
;;

(* A cut can expose a trailing '-' , which a DNS-1123 name cannot end with. *)
let rec trim_trailing_hyphen s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '-' then trim_trailing_hyphen (String.sub s 0 (n - 1)) else s
;;

let of_parts ~k8s_name ~(now : float) ~entropy =
  let suffix = Printf.sprintf "-manual-%d-%s" (int_of_float now) (entropy_hex entropy) in
  let budget = max 1 (max_length - String.length suffix) in
  let base =
    if String.length k8s_name <= budget
    then k8s_name
    else String.sub k8s_name 0 budget |> trim_trailing_hyphen
  in
  let base = if String.equal base "" then "fn" else base in
  base ^ suffix
;;

(* Deterministic for a given clock reading and entropy, so the shape is testable
   exactly; [mint] is the impure wrapper production uses. *)
let mint ~k8s_name =
  of_parts
    ~k8s_name
    ~now:(Unix.gettimeofday ())
    ~entropy:(Sol_cli_deployment_id.random_entropy ())
;;
