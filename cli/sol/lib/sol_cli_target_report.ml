(* Rendering a deployment target as a target rather than as kubectl output
   (FEAT-062).

   Kept pure on purpose: reachability is a fact the command obtains from the
   cluster and passes in, so the offline rendering — which is what runs by
   default — is the tested path, and no test needs a cluster.

   The one rule worth stating: the raw kube-context is *not* printed unless
   [verbose]. It is an implementation detail of how Sol reaches the cluster, and
   a target summary that leads with it teaches the user that the context is the
   thing they should care about — which is the opposite of DEC-020's point. *)

type kubernetes_status =
  | Not_configured
  | Configured of string
  | Reachable of string
  | Unreachable of string * string

(* kubectl quotes the context back when it cannot find one — observed: `error:
   context "prod-us-east-1" does not exist`. So the *reason* has to be filtered
   too, not only the context field: withholding the name from one line and
   printing it from the next would satisfy the rule only in appearance. *)

(** [describe ~verbose status] is the one-line Kubernetes summary. The raw
    context appears only when [verbose]: it is a mechanism, not the target's
    identity (DEC-020), and a summary that leads with it teaches the wrong
    lesson. *)
let redact ~needle ~replacement haystack =
  if needle = ""
  then haystack
  else (
    let length = String.length haystack in
    let n = String.length needle in
    let buffer = Buffer.create length in
    let rec go i =
      if i >= length
      then ()
      else if i + n <= length && String.sub haystack i n = needle
      then (
        Buffer.add_string buffer replacement;
        go (i + n))
      else (
        Buffer.add_char buffer haystack.[i];
        go (i + 1))
    in
    go 0;
    Buffer.contents buffer)
;;

let describe ~verbose = function
  | Not_configured ->
    "not configured — this target names no kube_context, so `sol deploy` has no cluster \
     to reach. `sol cloud init` writes it when Sol creates the cluster; for a cluster \
     you own, name its context in the target."
  | Configured context ->
    if verbose
    then Printf.sprintf "configured (%s) — not checked; pass --check to probe it" context
    else "configured — not checked; pass --check to probe it"
  | Reachable context ->
    if verbose then Printf.sprintf "reachable (%s)" context else "reachable"
  | Unreachable (context, reason) ->
    if verbose
    then Printf.sprintf "unreachable (%s): %s" context reason
    else
      Printf.sprintf
        "unreachable: %s"
        (redact ~needle:context ~replacement:"<context>" reason)
;;

let provider_name (target : Sol_cli_config.target) =
  Sol_cli_provider.to_string target.provider
;;

(* The same rows feed the text and JSON renderings, so the two cannot drift. *)
let rows ~verbose (target : Sol_cli_config.target) kubernetes =
  let core =
    [ "provider", provider_name target
    ; "region", target.region
    ; "cluster", Option.value target.cluster_name ~default:"(unnamed)"
    ; "registry", Option.value target.registry ~default:"(provider default)"
    ; "base domain", Option.value target.base_domain ~default:"(none)"
    ; "kubernetes", describe ~verbose kubernetes
    ]
  in
  if not verbose
  then core
  else
    core
    @ [ "env", target.env
      ; "target", target.name
      ; "kube context", Option.value target.kube_context ~default:"(none set)"
      ]
;;

let to_json ~verbose target kubernetes =
  `Assoc
    (List.map (fun (key, value) -> key, `String value) (rows ~verbose target kubernetes))
;;
