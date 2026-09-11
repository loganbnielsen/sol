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
  let kubeconfig =
    match kubeconfig with
    | Some path when String.trim path <> "" -> Some (String.trim path)
    | _ -> None
  in
  if context = ""
  then
    Error
      "no Kubernetes context is configured for this target, so Sol cannot tell where it \
       would deploy. Name one with `kube_context`, or let `sol cloud init` record it \
       when it provisions the cluster — Sol will not fall back to whatever kubectl is \
       currently pointed at."
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
