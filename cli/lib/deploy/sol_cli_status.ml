type domain_status =
  | Healthy
  | Degraded
  | Unknown of string
  | Not_deployed

type namespace_presence =
  | Ns_present
  | Ns_absent
  | Ns_unreadable of string

let first_line s =
  match String.split_on_char '\n' (String.trim s) with
  | [] -> String.trim s
  | line :: _ -> line
;;

let rollup_domain_status
      ~(ns_presence : namespace_presence)
      (diagnoses : Sol_cli_rollout_diagnosis.diagnosis list)
  =
  match ns_presence with
  | Ns_absent -> Not_deployed
  | Ns_unreadable why -> Unknown why
  | Ns_present ->
    if
      List.exists
        (function
          | Sol_cli_rollout_diagnosis.Unhealthy _ -> true
          | _ -> false)
        diagnoses
    then Degraded
    else (
      match
        List.find_opt
          (function
            | Sol_cli_rollout_diagnosis.Undetermined _ -> true
            | _ -> false)
          diagnoses
      with
      | Some (Sol_cli_rollout_diagnosis.Undetermined why) -> Unknown why
      | _ -> Healthy)
;;

let domain_status_to_string = function
  | Healthy -> "healthy"
  | Degraded -> "DEGRADED"
  | Unknown why -> Printf.sprintf "UNKNOWN (%s)" (first_line why)
  | Not_deployed -> "NOT DEPLOYED"
;;

type reachability =
  | Healthy
  | Unreachable of string
  | Not_checked

let reachability_to_string = function
  | Healthy -> "healthy"
  | Unreachable why -> "unreachable (" ^ why ^ ")"
  | Not_checked -> "not checked"
;;

let probe_url ~backend ~explicit_url ~default_local_url ~probe_path =
  match explicit_url with
  | Some base -> Some (base ^ probe_path)
  | None ->
    (match (backend : Sol_cli_observability_url.backend) with
     | Local -> Some (default_local_url ^ probe_path)
     | Self_hosted_durable | External -> None)
;;

let reachability_of_probe ~probe_url ~is_reachable =
  match probe_url with
  | None -> Not_checked
  | Some url ->
    (match is_reachable url with
     | Ok () -> Healthy
     | Error why -> Unreachable why)
;;

type observability_signal =
  | Loki
  | Prometheus

let signal_label = function
  | Loki -> "Loki"
  | Prometheus -> "Prometheus"
;;

let signal_flag = function
  | Loki -> "--loki-base-url"
  | Prometheus -> "--prometheus-base-url"
;;

let signal_port_forward = function
  | Loki -> "kubectl port-forward -n monitoring svc/loki 3100:3100"
  | Prometheus -> "kubectl port-forward -n monitoring svc/prometheus-server 9090:80"
;;

let not_configured_message ~signal ~backend =
  Printf.sprintf
    "not checked: %s has no default %s URL. Run '%s', then pass %s <url>"
    (Sol_cli_observability_url.backend_to_string backend)
    (signal_label signal)
    (signal_port_forward signal)
    (signal_flag signal)
;;

let unreachable_message ~url ~error = Printf.sprintf "couldn't reach %s: %s" url error

let reachability_line ~signal ~backend ~probe_url ~is_reachable =
  match probe_url with
  | None -> not_configured_message ~signal ~backend
  | Some url ->
    (match is_reachable url with
     | Ok () -> "healthy"
     | Error error -> unreachable_message ~url ~error)
;;

let service_is_declared ~k8s_name declared_k8s_names =
  List.mem k8s_name declared_k8s_names
;;

let pod_expectation_of_primitive
  : Sol_cli_manifest.primitive -> Sol_cli_rollout_diagnosis.pod_expectation
  = function
  | Fn -> Ephemeral
  | Svc | Worker -> Continuous
;;
