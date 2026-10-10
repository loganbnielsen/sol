(* Turn the deploy command's raw secret-emission options into the one validated
   backend the rest of the deploy consumes. External delivery is deliberately
   unavailable until its implementation milestone. *)

let dependent_flag flag = function
  | Some _ -> Some flag
  | None -> None
;;

let refuse_irrelevant ~backend flags =
  match List.filter_map Fun.id flags with
  | [] -> Ok ()
  | flags ->
    Error
      (Printf.sprintf
         "%s only apply with --secret-backend=external-secrets (got %s)"
         (String.concat ", " flags)
         backend)
;;

let emission_backend
      ~emit_to:_
      ~backend
      ~store_ref
      ~store_kind
      ~key_prefix
      ~refresh_interval
  =
  let dependent =
    [ dependent_flag "--secret-store-ref" store_ref
    ; dependent_flag "--secret-store-kind" store_kind
    ; dependent_flag "--key-prefix" key_prefix
    ; dependent_flag "--refresh-interval" refresh_interval
    ]
  in
  match backend with
  | None -> Result.map (fun () -> None) (refuse_irrelevant ~backend:"(omitted)" dependent)
  | Some "kubernetes-placeholder" ->
    Result.map
      (fun () -> Some Sol_cli_manifest.Kubernetes_placeholder)
      (refuse_irrelevant ~backend:"kubernetes-placeholder" dependent)
  | Some "kubernetes-live" ->
    Result.map
      (fun () -> Some Sol_cli_manifest.Kubernetes_live)
      (refuse_irrelevant ~backend:"kubernetes-live" dependent)
  | Some "external-secrets" ->
    Error
      "external secret delivery is not supported yet; externally managed keys cannot be \
       deployed"
  | Some other ->
    Error
      (Printf.sprintf
         "unknown --secret-backend value %S (expected: kubernetes-live | \
          kubernetes-placeholder | external-secrets)"
         other)
;;
