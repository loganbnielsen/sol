module O = Sol_cli_workload_ownership
module D = Sol_cli_plan_delta

let ctx = Sol_cli_kube_destination.local_context
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let with_fake_kubectl script f =
  let dir = Filename.temp_file "sol-ownership-kubectl" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let id ?(resource = "deployment") ?(namespace = "ns") ?(name = "app") () =
  { O.resource; namespace; name }
;;

let evidence ?(resource = "deployment") ?(namespace = "ns") ?(name = "app") uid =
  { Sol_cli_release_id.resource; namespace; name; uid }
;;

(* The one ownership decision: only an exact live/recorded UID match is ownership. *)
let test_owns () =
  check_bool "a matching UID is owned" true (O.owns ~recorded:(Some "u1") ~live_uid:"u1");
  check_bool
    "a different UID is not owned"
    false
    (O.owns ~recorded:(Some "u1") ~live_uid:"u2");
  check_bool "no evidence is never owned" false (O.owns ~recorded:None ~live_uid:"u1")
;;

let test_recorded_uid_is_keyed_by_the_whole_identity () =
  let owned = [ evidence "u1" ] in
  check_string
    "the exact identity finds its UID"
    "u1"
    (Option.value (O.recorded_uid owned (id ())) ~default:"");
  check_bool
    "a different kind is a different identity"
    true
    (O.recorded_uid owned (id ~resource:"cronjob" ()) = None);
  check_bool
    "a different name is a different identity"
    true
    (O.recorded_uid owned (id ~name:"other" ()) = None)
;;

let test_classify_declared () =
  let classified ~recorded live = O.classify_declared ~recorded live in
  (match classified ~recorded:None O.Live_absent with
   | O.Create -> ()
   | _ -> Windtrap.fail "no evidence and no live object is a create");
  (match classified ~recorded:(Some "u1") O.Live_absent with
   | O.Recorded_gone -> ()
   | _ -> Windtrap.fail "recorded evidence with no live object is recorded-but-gone");
  (match classified ~recorded:(Some "u1") (O.Live_present "u1") with
   | O.Owned_unchanged -> ()
   | _ -> Windtrap.fail "a matching live UID is owned");
  (match classified ~recorded:(Some "u1") (O.Live_present "u2") with
   | O.Live_not_owned -> ()
   | _ -> Windtrap.fail "a mismatched live UID is live-but-not-owned");
  match classified ~recorded:None (O.Live_unobservable "denied") with
  | O.Declared_unobservable reason ->
    check_string "the reason is preserved" "denied" reason
  | _ -> Windtrap.fail "an unobservable live object is unobservable"
;;

let test_classify_surplus () =
  (match O.classify_surplus ~recorded:(Some "u1") ~live_uid:"u1" with
   | O.Surplus_removable -> ()
   | _ -> Windtrap.fail "a matching UID makes a surplus object removable");
  (match O.classify_surplus ~recorded:(Some "u1") ~live_uid:"u2" with
   | O.Surplus_retained -> ()
   | _ -> Windtrap.fail "a mismatched UID retains a surplus object");
  match O.classify_surplus ~recorded:None ~live_uid:"u1" with
  | O.Surplus_retained -> ()
  | _ -> Windtrap.fail "no evidence retains a surplus object"
;;

(* Observation tells absence from unobservability. *)
let test_observe () =
  with_fake_kubectl "#!/bin/sh\nprintf '%s\\n' live-uid\n" (fun () ->
    match O.observe ~ctx (id ()) with
    | O.Live_present uid -> check_string "reads the live UID" "live-uid" uid
    | _ -> Windtrap.fail "a served object is present");
  with_fake_kubectl
    "#!/bin/sh\n\
     printf '%s\\n' 'Error from server (NotFound): deployments \"app\" not found' >&2\n\
     exit 1\n"
    (fun () ->
       match O.observe ~ctx (id ()) with
       | O.Live_absent -> ()
       | _ -> Windtrap.fail "a NotFound object is absent");
  with_fake_kubectl
    "#!/bin/sh\n\
     printf '%s\\n' 'error: the server could not find the requested resource' >&2\n\
     exit 1\n"
    (fun () ->
       match O.observe ~ctx (id ~resource:"rollout" ()) with
       | O.Live_unobservable reason ->
         check_bool
           "an unserved kind is unobservable, not absent"
           true
           (Sol_cli_string.contains ~needle:"not served" reason)
       | _ -> Windtrap.fail "an unserved kind must be unobservable");
  with_fake_kubectl
    "#!/bin/sh\n\
     printf '%s\\n' 'Unable to connect to the server: dial tcp 192.0.2.1:443' >&2\n\
     exit 1\n"
    (fun () ->
       match O.observe ~ctx (id ()) with
       | O.Live_unobservable _ -> ()
       | _ -> Windtrap.fail "an unreachable cluster must be unobservable")
;;

let test_delta_to_string () =
  let text =
    D.to_string
      (D.Delta
         { declared =
             [ id ~name:"api" (), O.Create
             ; id ~name:"svc" (), O.Live_not_owned
             ; ( id ~name:"gone" ()
               , O.Declared_unobservable "the rollout kind is not served" )
             ]
         ; surplus =
             [ id ~name:"old" (), O.Surplus_removable
             ; id ~name:"foreign" (), O.Surplus_retained
             ]
         ; unobservable = [ "cronjob", "Forbidden" ]
         })
  in
  List.iter
    (fun needle ->
       check_bool
         (Printf.sprintf "renders %S" needle)
         true
         (Sol_cli_string.contains ~needle text))
    [ "Live workload delta"
    ; "create"
    ; "live, not owned"
    ; "unobservable"
    ; "Surplus"
    ; "removable"
    ; "retained"
    ; "cronjob: Forbidden"
    ];
  check_bool
    "the deferred rendering names the reason"
    true
    (Sol_cli_string.contains
       ~needle:"deferred: no context"
       (D.to_string (D.Deferred "no context")))
;;

let listing =
  {|{"items":[
    {"metadata":{"namespace":"ns","name":"app","uid":"live-uid"},"spec":{"template":{"metadata":{"labels":{"workspace":"ws"}}}}},
    {"metadata":{"namespace":"ns","name":"old","uid":"old-uid"},"spec":{"template":{"metadata":{"labels":{"workspace":"ws"}}}}},
    {"metadata":{"namespace":"ns","name":"foreign","uid":"foreign-uid"},"spec":{"template":{"metadata":{"labels":{"workspace":"ws"}}}}}
  ]}|}
;;

let compute_script =
  Printf.sprintf
    {|#!/bin/sh
case "$3 $4" in
  "get deployment")
    case "$5" in
      -A) printf '%%s' %s ;;
      app) printf '%%s\n' live-uid ;;
      gone|new) printf '%%s\n' 'Error from server (NotFound): deployments "app" not found' >&2; exit 1 ;;
      *) exit 1 ;;
    esac ;;
  "get rollout")
    printf '%%s\n' 'error: the server could not find the requested resource' >&2; exit 1 ;;
  "get cronjob")
    printf '%%s\n' 'Error from server (Forbidden): cronjobs is forbidden' >&2; exit 1 ;;
  *) exit 1 ;;
esac
|}
    (Filename.quote listing)
;;

let declared_named name declared =
  List.find (fun ((i : O.identity), _) -> String.equal i.name name) declared
;;

let test_compute () =
  let evidence =
    Ok
      [ evidence ~name:"app" "live-uid"
      ; evidence ~name:"gone" "gone-uid"
      ; evidence ~name:"old" "old-uid"
      ]
  in
  let declared = [ id ~name:"app" (); id ~name:"gone" (); id ~name:"new" () ] in
  with_fake_kubectl compute_script (fun () ->
    match D.compute ~ctx ~workspace:"ws" ~evidence ~declared with
    | D.Deferred reason -> Windtrap.fail ("expected a delta, got deferred: " ^ reason)
    | D.Delta { declared; surplus; unobservable } ->
      (match declared_named "app" declared with
       | _, O.Owned_unchanged -> ()
       | _ -> Windtrap.fail "app should be owned and unchanged");
      (match declared_named "gone" declared with
       | _, O.Recorded_gone -> ()
       | _ -> Windtrap.fail "gone should be recorded-but-gone");
      (match declared_named "new" declared with
       | _, O.Create -> ()
       | _ -> Windtrap.fail "new should be a create");
      check_bool
        "the declared object is not also surplus"
        true
        (not
           (List.exists (fun ((i : O.identity), _) -> String.equal i.name "app") surplus));
      (match List.assoc_opt "old" (List.map (fun (i, s) -> i.O.name, s) surplus) with
       | Some O.Surplus_removable -> ()
       | _ -> Windtrap.fail "old should be a removable surplus");
      (match List.assoc_opt "foreign" (List.map (fun (i, s) -> i.O.name, s) surplus) with
       | Some O.Surplus_retained -> ()
       | _ -> Windtrap.fail "foreign should be a retained surplus");
      check_bool
        "the unobservable kind is reported, not silently empty"
        true
        (List.exists (fun (resource, _) -> String.equal resource "cronjob") unobservable))
;;

let test_compute_defers_without_evidence () =
  match
    D.compute
      ~ctx
      ~workspace:"ws"
      ~evidence:(Error "the current release record could not be read")
      ~declared:[ id () ]
  with
  | D.Deferred reason ->
    check_string
      "the reason is preserved"
      "the current release record could not be read"
      reason
  | D.Delta _ -> Windtrap.fail "unreadable evidence must defer, not emit an empty delta"
;;

let%test "ownership: only an exact live/recorded UID match is ownership" = test_owns ()

let%test "ownership: evidence is keyed by the whole identity" =
  test_recorded_uid_is_keyed_by_the_whole_identity ()
;;

let%test "ownership: declared classification" = test_classify_declared ()
let%test "ownership: surplus classification" = test_classify_surplus ()
let%test "ownership: observation separates absence from unobservability" = test_observe ()
let%test "plan delta: rendering" = test_delta_to_string ()
let%test "plan delta: compute classifies declared and surplus" = test_compute ()

let%test "plan delta: unreadable evidence defers" =
  test_compute_defers_without_evidence ()
;;
