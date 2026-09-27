(* FEAT-063: every kubectl invocation is scoped to an explicit destination.

   The destination arrives as a [Sol_cli_kube_destination.context] and is applied
   here, once — [--context] plus, when one is scoped, [KUBECONFIG]. Nothing below
   reads the machine's ambient context, and no caller can inherit it by
   accident: the parameter is required, so a call site that forgets to say where
   it is talking to does not compile.

   This is a lib-level seam, so the destination stays a destination: it says
   *where* an operation reaches a cluster and never *what* is being deployed
   (FEAT-061 — scope travels on its own channel). *)

let invocation ?timeout_s ~ctx args =
  Sol_cli_process.cmd
    ~env:(Sol_cli_kube_destination.context_environment ctx)
    ?timeout_s
    ([ "kubectl" ] @ Sol_cli_kube_destination.kubectl_context_args ctx @ args)
;;

(* REFAC-124: every call below is one [kubectl] run, [Ok] only on exit 0; a caller
   for which a particular failure means something matches [Non_zero]. *)
let kubectl ?timeout_s ~ctx args = Sol_cli_process.run (invocation ?timeout_s ~ctx args)
let succeeded r = Result.map ignore r
let apply ~ctx ~file = kubectl ~ctx [ "apply"; "-f"; file ] |> succeeded

let apply_dry_run ~ctx ~file =
  kubectl ~ctx [ "apply"; "-f"; file; "--dry-run=server" ] |> succeeded
;;

let get ~ctx ~resource ~name ~namespace ~output =
  kubectl ~ctx [ "get"; resource; name; "-n"; namespace; "-o"; output ]
;;

let get_raw ~ctx ~args = kubectl ~ctx args

(* REFAC-125: what kind of failure a kubectl error is, for the callers that act on
   it. A view onto the error, not a replacement for it: the error itself travels
   on unchanged and every message is rendered from it, in kubectl's own words.

   kubectl prints an API error as "Error from server (<Reason>): ...", where
   <Reason> is the API server's status reason; that token, not the prose after
   it, is what is read. A missing resource *type* (no CRD) and an unauthenticated
   client are client-side messages with no reason token, so their wording is
   named here -- the one place kubectl's wording is known. *)
type reason =
  | Not_found
  | Already_exists
  | Conflict
  | No_resource_type
  | Refused
  | Other

let status_reason text =
  let prefix = "Error from server (" in
  let n = String.length prefix in
  let rec find i =
    if i + n > String.length text
    then None
    else if String.sub text i n = prefix
    then (
      match String.index_from_opt text (i + n) ')' with
      | Some j -> Some (String.sub text (i + n) (j - i - n))
      | None -> None)
    else find (i + 1)
  in
  find 0
;;

let classify (error : Sol_cli_process.error) =
  match error with
  | Non_zero f ->
    let text = f.stderr ^ "\n" ^ f.stdout in
    let says needle = Sol_cli_string.contains ~needle text in
    if says "doesn't have a resource type" || says "could not find the requested resource"
    then No_resource_type
    else if
      says "You must be logged in"
      || says "the server has asked for the client to provide credentials"
    then Refused
    else (
      match status_reason text with
      | Some "NotFound" -> Not_found
      | Some "AlreadyExists" -> Already_exists
      | Some "Conflict" -> Conflict
      | Some ("Unauthorized" | "Forbidden") -> Refused
      | _ -> Other)
  | Spawn_failed _ | Timeout _ -> Other
;;

(* REFAC-125: [get] for an object that may not exist -- [Ok None] when kubectl
   answers NotFound. Absence is read from the API's status reason, the same
   mechanism [classify] uses for every verb, rather than a second one
   ([--ignore-not-found] exists only for get and delete). *)
let get_if_present ~ctx ~args =
  match kubectl ~ctx args with
  | Ok (o : Sol_cli_process.output) -> Ok (Some o.stdout)
  | Error e when classify e = Not_found -> Ok None
  | Error e -> Error e
;;

let logs ~ctx ~pod ~namespace ~container =
  let container_args = Option.fold container ~none:[] ~some:(fun c -> [ "-c"; c ]) in
  kubectl ~ctx ([ "logs"; pod; "-n"; namespace ] @ container_args)
;;

let rollout_status ~ctx ~kind_name ~namespace =
  kubectl ~ctx [ "rollout"; "status"; kind_name; "-n"; namespace ]
;;

let rollout_status_with_timeout ~ctx ~kind_name ~namespace ~timeout_s =
  kubectl
    ~ctx
    [ "rollout"
    ; "status"
    ; kind_name
    ; "-n"
    ; namespace
    ; Printf.sprintf "--timeout=%ds" timeout_s
    ]
;;

let rollout_restart ~ctx ~kind ~namespace =
  kubectl ~ctx [ "rollout"; "restart"; kind; "-n"; namespace ]
;;

let patch ~ctx ~resource ~name ~namespace ~patch_type ~patch =
  kubectl
    ~ctx
    [ "patch"; resource; name; "-n"; namespace; "--type"; patch_type; "-p"; patch ]
;;

(* FEAT-072: "AlreadyExists" is the atomic-acquire signal the boundary lease relies
   on, so the caller reads it from the [Non_zero] branch. *)
let create ~ctx ~file = kubectl ~ctx [ "create"; "-f"; file ]

(* FEAT-072: optimistic concurrency travels *in the object*: when [file] carries
   [metadata.resourceVersion], the API server rejects a stale write, and the
   caller sees the conflict in the [Non_zero] branch. There is deliberately no
   [--resource-version] flag — it is not present in every kubectl (the CI runner's
   does not have it). *)
let replace ~ctx ~file = kubectl ~ctx [ "replace"; "-f"; file ]

let create_job_from_cronjob ~ctx ~cronjob ~job_name ~namespace =
  kubectl ~ctx [ "create"; "job"; job_name; "--from=cronjob/" ^ cronjob; "-n"; namespace ]
;;

let delete ~ctx ~resource ~name ~namespace =
  kubectl ~ctx [ "delete"; resource; name; "-n"; namespace; "--ignore-not-found" ]
  |> succeeded
;;

(* A probe answers "is it reachable", and now also "and if not, what did kubectl
   say". The verdict is only half a diagnosis: the reason goes to stderr and used
   to be discarded here, which left `sol target show --check` able to report
   "unreachable" and nothing else (REFAC-084).

   Bounded on purpose: a probe is an inspection command, so it should not hang on
   a cluster that is simply unreachable. Sol's runner already spawns children with
   stdin on /dev/null (so a credential prompt returns EOF instead of waiting for
   input), and [timeout_s] bounds a network wait. *)
let probe_timeout_s = 15.0

(* What kubectl answered: it succeeded, or it ran and failed, with what it said.
   An [Error] means kubectl could not be run at all — distinct from running and
   failing. *)
type probe =
  | Succeeded
  | Failed of Sol_cli_process.failure

let probe_result ~ctx ~args =
  match kubectl ~timeout_s:probe_timeout_s ~ctx args with
  | Ok _ -> Ok Succeeded
  | Error (Sol_cli_process.Non_zero failure) -> Ok (Failed failure)
  | Error e -> Error ("kubectl could not be run: " ^ Sol_cli_process.error_to_string e)
;;

(* A boolean probe cannot say the third thing: "kubectl could not be run" and
   "kubectl ran and said no" both collapse to `false`, and a caller that prints
   that as a fact about the cluster reports an absence it never established
   (FND-0024). [Present] and [Absent reason] are what kubectl answered; [reason]
   is what it said. [Uncheckable why] is that it could not be asked at all. The
   classifier is pure so the distinction is unit-testable without a cluster. *)
type presence =
  | Present
  | Absent of string
  | Uncheckable of string

let presence_of_probe_result = function
  | Ok Succeeded -> Present
  | Ok (Failed failure) ->
    Absent
      (Printf.sprintf
         "kubectl exited %d: %s"
         failure.exit_code
         (Sol_cli_process.failure_message failure))
  | Error why -> Uncheckable why
;;

let presence ~ctx ~args = presence_of_probe_result (probe_result ~ctx ~args)
