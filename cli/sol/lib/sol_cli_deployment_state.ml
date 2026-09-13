type execution_outcome =
  | Applied of
      { namespace : string
      ; name : string
      ; image : string
      ; consumer_groups : string list
      }
  | Emitted of { file : string }
  | Dry_run
  | Failed of
      { phase : string
      ; message : string
      }

(* BUG-025: the name embeds the workspace, and '_' or uppercase are illegal in
   a Kubernetes object name — so a workspace like [ci_smoke] produced
   "sol-deploy-state-ci_smoke", which the API server rejects. Because the apply
   result used to be ignored below, that failure was silent. *)
let deploy_state_configmap_name workspace =
  Printf.sprintf "sol-deploy-state-%s" (Sol_cli_kubernetes_name.sanitize_name workspace)
;;

(* FEAT-063: the state ConfigMap lives in the cluster the target names, so every
   entry point takes the destination-side context and passes it to kubectl. *)
let load_deployed_groups ~ctx workspace =
  let name = deploy_state_configmap_name workspace in
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:"configmap"
      ~name
      ~namespace:"default"
      ~output:"jsonpath={.data.consumer_groups}"
  with
  | Error _ -> []
  | Ok r when r.Sol_cli_process.exit_code <> 0 -> []
  | Ok r ->
    String.split_on_char '\n' r.Sol_cli_process.stdout
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
;;

let save_deployed_groups ~ctx workspace groups =
  let name = deploy_state_configmap_name workspace in
  let value = String.concat "\n" groups in
  let apply_json =
    Printf.sprintf
      {|{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","namespace":"default"},"data":{"consumer_groups":"%s"}}|}
      (String.escaped name)
      (String.escaped value)
  in
  let path = Filename.temp_file "sol-state-" ".json" in
  let oc = open_out path in
  output_string oc apply_json;
  close_out oc;
  (* BUG-025: report a failed write. The consumer-group drift check depends on
     this object existing, so ignoring the result let the check run against
     nothing while looking healthy. *)
  (match Sol_cli_kubectl.apply ~ctx ~file:path with
   | Ok () -> ()
   | Error e ->
     Printf.eprintf
       "warning: could not record deploy state (%s): %s\n%!"
       name
       (Sol_cli_process.error_to_string e));
  try Sys.remove path with
  | _ -> ()
;;

let record_outcome ~ctx workspace outcome =
  match outcome with
  | Applied { consumer_groups; _ } -> save_deployed_groups ~ctx workspace consumer_groups
  | Emitted _ | Dry_run | Failed _ -> ()
;;

let removed_consumer_groups ~prev ~next =
  List.filter (fun g -> not (List.mem g next)) prev
;;
