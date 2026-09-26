type t =
  { context : string
  ; kubeconfig : string option
  }

let to_string { context; kubeconfig } =
  match kubeconfig with
  | Some path -> Printf.sprintf "%s (kubeconfig %s)" context path
  | None -> context
;;

let of_context ?kubeconfig context =
  let context = String.trim context in
  let kubeconfig = Sol_cli_string.non_blank_opt kubeconfig in
  if context = ""
  then
    Error
      "no Kubernetes context is configured for this target, so Sol cannot tell where it \
       would deploy. Name one with `kube_context` — after `sol cloud apply`, run the \
       printed `deploy_kubeconfig_command` output and add the resulting context name — \
       Sol will not fall back to whatever kubectl is currently pointed at."
  else Ok { context; kubeconfig }
;;

let local = { context = "k3d-sol-local"; kubeconfig = None }
let kubectl_args { context; _ } = [ "--context"; context ]
let helm_args { context; _ } = [ "--kube-context"; context ]

let environment ({ kubeconfig; _ } : t) =
  match kubeconfig with
  | Some path -> [ "KUBECONFIG", path ]
  | None -> []
;;

(* FEAT-063: the value threaded through the operation helpers. A record rather
   than a bare [t] so the next destination-side input (credential scoping) rides
   the same channel instead of starting a second refactor over the same call
   graph. Scope deliberately does NOT live here (FEAT-061): the Kubernetes seam
   learns *where*, never *what*. *)
type context = { destination : t }

let context_of_destination destination = { destination }
let local_context = { destination = local }
let kubectl_context_args (ctx : context) = kubectl_args ctx.destination
let helm_context_args (ctx : context) = helm_args ctx.destination
let context_environment (ctx : context) = environment ctx.destination
let context_to_string (ctx : context) = to_string ctx.destination

(* FEAT-063: [execvpe]/[create_process_env] take a whole environment, not a
   delta, so the destination's [KUBECONFIG] has to be merged into the ambient
   one here rather than handed over on its own. Centralising it means the exec
   paths (logs follow-mode, the temporary port-forwards) cannot apply
   [--context] while forgetting the kubeconfig — the exact pair-drift this
   ticket exists to prevent. *)
let child_environment (ctx : context) =
  let overrides = context_environment ctx in
  if overrides = []
  then Unix.environment ()
  else (
    let keys = List.map fst overrides in
    let base =
      Array.to_list (Unix.environment ())
      |> List.filter (fun entry ->
        match String.index_opt entry '=' with
        | None -> true
        | Some i ->
          let name = String.sub entry 0 i in
          not (List.mem name keys))
    in
    Array.of_list (base @ List.map (fun (k, v) -> k ^ "=" ^ v) overrides))
;;
