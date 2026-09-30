let target : Sol_cli_config.target =
  { name = "prod/gcp/us-central1"
  ; env = "prod"
  ; provider = Sol_cli_provider.Gcp
  ; region = "us-central1"
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = Some "acme-prod"
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = None
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; provider_fields = [ "gcp", [ "project_id", "acme-project" ] ]
  }
;;

let fake_gcloud ~log ~node_pools_out ~nats_out ~list_exit =
  Printf.sprintf
    {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$*" in
  *"container node-pools list"*)
    printf '%%s' %s%s
    exit %d
    ;;
  *"routers nats list"*)
    printf '%%s' %s
    exit 0
    ;;
esac
exit 0
|}
    log
    (Filename.quote node_pools_out)
    (if list_exit = 0 then "" else " >&2")
    list_exit
    (Filename.quote nats_out)
;;

let with_fake_gcloud ~node_pools_out ~nats_out ~list_exit f =
  let dir = Filename.temp_file "sol-fake-gcloud-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "gcloud" in
  let oc = open_out bin in
  output_string oc (fake_gcloud ~log ~node_pools_out ~nats_out ~list_exit);
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  let old_default =
    try Some (Sys.getenv "CLOUDSDK_COMPUTE_REGION") with
    | Not_found -> None
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Unix.putenv "CLOUDSDK_COMPUTE_REGION" "europe-west1";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (match old_default with
       | Some value -> Unix.putenv "CLOUDSDK_COMPUTE_REGION" value
       | None -> ());
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let calls log = In_channel.with_open_text log In_channel.input_all

let arguments_of ~log ~contains =
  calls log
  |> String.split_on_char '\n'
  |> List.filter (fun line -> Sol_cli_string.contains ~needle:contains line)
;;

let class_of (o : Sol_cli_absence.observation) =
  match o with
  | Sol_cli_absence.Absent a -> a.resource_class
  | Present p -> p.resource_class
  | External e -> e.resource_class
  | Not_attributable n -> n.resource_class
  | Unobservable u -> u.resource_class
;;

let only observations resource_class =
  List.find (fun o -> String.equal (class_of o) resource_class) observations
;;

let with_calls ~node_pools_out ~nats_out ~list_exit f =
  with_fake_gcloud ~node_pools_out ~nats_out ~list_exit (fun () ->
    let observations =
      Sol_cli_gcp_absence.observations target ~cluster_name:"acme-prod"
    in
    let log =
      match Sys.getenv_opt "PATH" with
      | Some path -> Filename.concat (List.hd (String.split_on_char ':' path)) "calls.log"
      | None -> Alcotest.fail "PATH is unset"
    in
    f ~log ~observations)
;;

let test_location_is_explicit_on_every_regional_check () =
  with_calls ~node_pools_out:"" ~nats_out:"" ~list_exit:0 (fun ~log ~observations:_ ->
    let node_pools = arguments_of ~log ~contains:"node-pools list" in
    Alcotest.(check int) "one node-pool check" 1 (List.length node_pools);
    Alcotest.(check bool)
      "the node-pool check carries the target's location"
      true
      (Sol_cli_string.contains ~needle:"--location us-central1" (List.hd node_pools));
    let nats = arguments_of ~log ~contains:"nats list" in
    Alcotest.(check int) "one Cloud NAT check" 1 (List.length nats);
    Alcotest.(check bool)
      "the Cloud NAT check carries the target's router region"
      true
      (Sol_cli_string.contains ~needle:"--router-region us-central1" (List.hd nats));
    let regional =
      arguments_of ~log ~contains:"routers list"
      @ arguments_of ~log ~contains:"subnets list"
    in
    Alcotest.(check bool)
      "and so does every other regional list, with the flag gcloud accepts"
      true
      (List.for_all
         (fun call -> Sol_cli_string.contains ~needle:"--regions us-central1" call)
         regional))
;;

let test_the_target_region_beats_the_configured_default () =
  with_calls ~node_pools_out:"" ~nats_out:"" ~list_exit:0 (fun ~log ~observations:_ ->
    let all = calls log in
    Alcotest.(check bool)
      "no check follows the operator's default region"
      false
      (Sol_cli_string.contains ~needle:"europe-west1" all))
;;

let test_an_empty_inventory_is_absent () =
  with_calls ~node_pools_out:"" ~nats_out:"" ~list_exit:0 (fun ~log:_ ~observations ->
    (match only observations "GKE node pool" with
     | Sol_cli_absence.Absent _ -> ()
     | _ -> Alcotest.fail "an empty node-pool list must be Absent");
    match only observations "Cloud NAT" with
    | Sol_cli_absence.Absent _ -> ()
    | _ -> Alcotest.fail "an empty Cloud NAT list must be Absent")
;;

let test_a_present_resource_is_reported () =
  with_calls
    ~node_pools_out:"acme-prod-pool-1\n"
    ~nats_out:"acme-prod-nat\n"
    ~list_exit:0
    (fun ~log:_ ~observations ->
       (match only observations "GKE node pool" with
        | Sol_cli_absence.Present p ->
          Alcotest.(check (list string))
            "the node pool is reported"
            [ "acme-prod-pool-1" ]
            p.found
        | _ -> Alcotest.fail "a present node pool must be Present");
       match only observations "Cloud NAT" with
       | Sol_cli_absence.Present p ->
         Alcotest.(check (list string)) "the NAT is reported" [ "acme-prod-nat" ] p.found
       | _ -> Alcotest.fail "a present NAT must be Present")
;;

let test_a_refused_list_is_unobservable () =
  with_calls
    ~node_pools_out:"One of [--location, --zone, --region] must be supplied\n"
    ~nats_out:""
    ~list_exit:1
    (fun ~log:_ ~observations ->
       match only observations "GKE node pool" with
       | Sol_cli_absence.Unobservable u ->
         Alcotest.(check bool)
           "the reason is the provider's"
           true
           (Sol_cli_string.contains ~needle:"must be supplied" u.reason)
       | _ -> Alcotest.fail "a refused list must be Unobservable")
;;

let () =
  Alcotest.run
    "gcp_absence"
    [ ( "location-scoped inventory"
      , [ Alcotest.test_case
            "passes the target location explicitly"
            `Quick
            test_location_is_explicit_on_every_regional_check
        ; Alcotest.test_case
            "the target region beats the configured default"
            `Quick
            test_the_target_region_beats_the_configured_default
        ; Alcotest.test_case
            "an empty inventory is Absent"
            `Quick
            test_an_empty_inventory_is_absent
        ; Alcotest.test_case
            "a present resource is Present"
            `Quick
            test_a_present_resource_is_reported
        ; Alcotest.test_case
            "a refused list is Unobservable"
            `Quick
            test_a_refused_list_is_unobservable
        ] )
    ]
;;
