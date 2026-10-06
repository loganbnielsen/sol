(* Turn the deploy command's raw secret-emission options into the one validated
   backend the rest of the deploy consumes. The operator's request is never
   silently rewritten into a different backend, and every option that only makes
   sense for External Secrets is refused when no External Secrets request was
   made. *)

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

let external_secrets ~emit_to ~store_ref ~store_kind ~key_prefix ~refresh_interval =
  match emit_to with
  | None ->
    Error
      "--secret-backend=external-secrets requires --emit-to: it emits an ExternalSecret \
       for a GitOps repository and cannot write live secret values directly"
  | Some _ ->
    (match store_ref with
     | None | Some "" ->
       Error "--secret-store-ref is required when --secret-backend=external-secrets"
     | Some store_ref ->
       (match
          Sol_cli_manifest.secret_store_kind_of_string
            (Option.value store_kind ~default:"ClusterSecretStore")
        with
        | Error message -> Error message
        | Ok store_kind ->
          (match
             Sol_cli_manifest.refresh_interval_of_string
               (Option.value refresh_interval ~default:"1h")
           with
           | Error message -> Error message
           | Ok refresh_interval ->
             Ok
               (Some
                  (Sol_cli_manifest.External_secrets
                     { store_ref
                     ; store_kind
                     ; key_prefix = Option.value key_prefix ~default:""
                     ; refresh_interval
                     })))))
;;

let emission_backend
      ~emit_to
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
    external_secrets ~emit_to ~store_ref ~store_kind ~key_prefix ~refresh_interval
  | Some other ->
    Error
      (Printf.sprintf
         "unknown --secret-backend value %S (expected: kubernetes-live | \
          kubernetes-placeholder | external-secrets)"
         other)
;;
