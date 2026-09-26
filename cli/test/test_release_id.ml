(* FEAT-069: release identity semantics.

   These tests are the contract, not a smoke check. The hard failures in content
   addressing are not "the hash is wrong" -- they are "two things that mean the
   same thing hash differently" (ordering) and "two things that mean different
   things hash the same" (encoding ambiguity, or a field that should have counted
   and did not). Both are covered here, and the secret rule is pinned so that a
   later "fix" to the hash cannot silently change what a release identity means. *)

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let wl
      ?(domain = "payments")
      ?(primitive = "svc")
      ?(config = [])
      ?(secrets = [])
      ?(schedule = None)
      ?(replicas = 1)
      ?(availability = "single")
      ?(consumes_kafka = false)
      ?(cpu = "100m")
      ?(memory = "128Mi")
      ?(extra_labels = [])
      ?(volumes = [])
      ?(rollout = "rolling_update")
      ?(ingress_host = None)
      ?(ingress_path = None)
      ?(cluster_issuer = "letsencrypt-prod")
      ?(calls = [])
      name
      image
  =
  { Sol_cli_release_id.domain
  ; name
  ; primitive
  ; image
  ; config
  ; secrets
  ; schedule
  ; replicas
  ; availability
  ; consumes_kafka
  ; cpu
  ; memory
  ; extra_labels
  ; volumes
  ; rollout
  ; ingress_host
  ; ingress_path
  ; cluster_issuer
  ; calls
  }
;;

let content ?(workspace = "acme") ?(environment = Some "prod") workloads =
  { Sol_cli_release_id.workspace; environment; workloads }
;;

(* [t] is abstract on purpose; the tests compare the rendered id, which is what
   a label carries. *)
let id c = Sol_cli_release_id.to_string (Sol_cli_release_id.of_content c)

let test_deterministic () =
  let c = content [ wl "charge_svc" "acme/charge:1" ] in
  check_string "same content, same id" (id c) (id c)
;;

(* Discovery order is not semantic. If this failed, every release identity would
   depend on filesystem enumeration order. *)
let test_workload_order_is_not_semantic () =
  let a = wl "charge_svc" "acme/charge:1" in
  let b = wl "settle_worker" "acme/settle:1" in
  check_string
    "workload order does not change identity"
    (id (content [ a; b ]))
    (id (content [ b; a ]))
;;

let test_config_key_order_is_not_semantic () =
  let a = [ "LOG_LEVEL", "info"; "POOL_SIZE", "10" ] in
  let b = [ "POOL_SIZE", "10"; "LOG_LEVEL", "info" ] in
  check_string
    "config key order does not change identity"
    (id (content [ wl ~config:a "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~config:b "charge_svc" "acme/charge:1" ]))
;;

let test_secret_reference_order_is_not_semantic () =
  let a = [ "DATABASE_URL", "db-prod"; "API_KEY", "api-prod" ] in
  let b = [ "API_KEY", "api-prod"; "DATABASE_URL", "db-prod" ] in
  check_string
    "secret reference order does not change identity"
    (id (content [ wl ~secrets:a "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~secrets:b "charge_svc" "acme/charge:1" ]))
;;

let test_extra_label_order_is_not_semantic () =
  let a = [ "team", "payments"; "tier", "edge" ] in
  let b = [ "tier", "edge"; "team", "payments" ] in
  check_string
    "extra label order does not change identity"
    (id (content [ wl ~extra_labels:a "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~extra_labels:b "charge_svc" "acme/charge:1" ]))
;;

(* The other half: things that *do* mean a different running release must change
   the identity, or the join key silently merges two different releases. *)
let test_image_change_changes_identity () =
  check_bool
    "a different image is a different release"
    true
    (id (content [ wl "charge_svc" "acme/charge:2" ])
     <> id (content [ wl "charge_svc" "acme/charge:1" ]))
;;

let test_scaling_change_changes_identity () =
  check_bool
    "different replicas is a different release"
    true
    (id (content [ wl ~replicas:3 "charge_svc" "acme/charge:1" ])
     <> id (content [ wl ~replicas:1 "charge_svc" "acme/charge:1" ]))
;;

let test_config_value_change_changes_identity () =
  check_bool
    "a changed config value is a different release"
    true
    (id (content [ wl ~config:[ "POOL_SIZE", "20" ] "charge_svc" "acme/charge:1" ])
     <> id (content [ wl ~config:[ "POOL_SIZE", "10" ] "charge_svc" "acme/charge:1" ]))
;;

let test_workspace_and_environment_change_identity () =
  check_bool
    "a different workspace is a different release"
    true
    (id (content [ wl "charge_svc" "acme/charge:1" ])
     <> id (content ~workspace:"other" [ wl "charge_svc" "acme/charge:1" ]));
  check_bool
    "a different environment is a different release"
    true
    (id (content ~environment:(Some "prod") [ wl "charge_svc" "acme/charge:1" ])
     <> id (content ~environment:(Some "staging") [ wl "charge_svc" "acme/charge:1" ]));
  check_bool
    "no environment differs from an empty one"
    true
    (id (content ~environment:None [ wl "charge_svc" "acme/charge:1" ])
     <> id (content ~environment:(Some "") [ wl "charge_svc" "acme/charge:1" ]))
;;

(* The deliberate rule, pinned as a test rather than left as prose: secrets enter
   the identity as *references*. Rotating db-prod's value is operational state
   and must not mint a new release; pointing at a different secret must. *)
let test_secret_references_count_and_values_do_not () =
  check_bool
    "a different secret reference is a different release"
    true
    (id
       (content
          [ wl ~secrets:[ "DATABASE_URL", "db-prod" ] "charge_svc" "acme/charge:1" ])
     <> id
          (content
             [ wl ~secrets:[ "DATABASE_URL", "db-other" ] "charge_svc" "acme/charge:1" ])
    );
  (* A rotation cannot even be expressed: the projection has no field for secret
     material, so "same reference, new value" is the same identity by
     construction. This asserts the *shape* of the rule, which is the part a
     future change could break. *)
  let with_reference =
    wl ~secrets:[ "DATABASE_URL", "db-prod" ] "charge_svc" "acme/charge:1"
  in
  check_bool
    "the projection carries the reference, not the material"
    true
    (let s = Sol_cli_release_id.canonical_string (content [ with_reference ]) in
     let contains needle = Sol_cli_string.contains ~needle s in
     contains "DATABASE_URL" && contains "db-prod")
;;

(* A bare separator would encode ("ab", "c") and ("a", "bc") identically. This is
   the classic canonicalisation bug, so it gets its own test. *)
let test_encoding_is_unambiguous () =
  check_bool
    "adjacent fields cannot bleed into each other"
    true
    (id (content [ wl "ab" "c" ]) <> id (content [ wl "a" "bc" ]))
;;

let test_id_is_a_legal_label_value () =
  let value = id (content [ wl "charge_svc" "acme/charge:1" ]) in
  check_bool "short enough for a label value" true (String.length value <= 63);
  check_bool
    "starts with an alphanumeric"
    true
    (match value.[0] with
     | 'a' .. 'z' | '0' .. '9' -> true
     | _ -> false);
  let legal =
    String.for_all
      (function
        | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> true
        | _ -> false)
      value
  in
  check_bool "only label-value characters" true legal
;;

let test_of_string_round_trips_and_validates () =
  let rendered = id (content [ wl "charge_svc" "acme/charge:1" ]) in
  (match Sol_cli_release_id.of_string rendered with
   | Ok parsed -> check_string "round trip" rendered (Sol_cli_release_id.to_string parsed)
   | Error msg -> Alcotest.fail ("valid id rejected: " ^ msg));
  List.iter
    (fun bad ->
       check_bool
         (Printf.sprintf "rejects %S" bad)
         true
         (match Sol_cli_release_id.of_string bad with
          | Ok _ -> false
          | Error _ -> true))
    [ ""
    ; "r-"
    ; "r-abc"
    ; "r-0123456789abcdefg"
    ; "R-0123456789abcdef"
    ; "0123456789abcdef"
    ; "r-0123456789ABCDEF"
    ]
;;

(* The encoding is an identity function with a version tag, so it gets a known
   vector. Not because this particular hash is sacred, but because the canonical
   encoder changing must be an explicit migration event: if this fails, either
   [encoding_version] was bumped deliberately (then update the vector) or the
   encoding drifted by accident (then fix the encoding). Content-addressed
   identifiers become durable API quickly, so this is cheap insurance. *)
let test_known_vector () =
  check_string
    "known id for a fixed content"
    (* BUG-026: sol-release-v2 widens the projection to every manifest-affecting
       input, so the vector moved deliberately. AUDIT-080 adds the declared
       availability, moving it again to sol-release-v3. *)
    "r-41a1291ca74157ee"
    (id
       (content
          [ wl
              ~config:[ "LOG_LEVEL", "info" ]
              ~secrets:[ "DATABASE_URL", "db-prod" ]
              "charge_svc"
              "acme/charge:1"
          ]))
;;

(* The deliberate choice, named: environment identity is part of release identity
   (model A), not merely whatever the resolved workload state happens to be
   (model B). The two contents below resolve to byte-identical workload state and
   still differ, because a release is "this release of this workspace in this
   environment" -- [r-x] is a join key inside an environment-aware operational
   system, not a generic OCI/Nix-style content hash.

   Pinned because "content-addressed" reads as though environment names ought to
   be excluded, so somebody could reasonably "simplify" this away. *)
let test_environment_identity_counts_not_just_resolved_state () =
  let same_state =
    [ wl ~config:[ "FOO", "1" ] ~replicas:2 "charge_svc" "acme/charge:1" ]
  in
  check_bool
    "identical resolved state in two environments is two releases"
    true
    (id (content ~environment:(Some "staging") same_state)
     <> id (content ~environment:(Some "prod") same_state));
  (* The other half, and the one that keeps deploys idempotent: within one
     environment, identical resolved state is the *same* release, so re-running
     a deploy is not a new identity and does not churn the pod template. *)
  check_string
    "identical resolved state in one environment is one release"
    (id (content ~environment:(Some "prod") same_state))
    (id (content ~environment:(Some "prod") same_state));
  (* Local (no target) is its own environment rather than "unknown": [sol up]
     releases must not collide with a target's releases. *)
  check_bool
    "no environment is its own identity, not a wildcard"
    true
    (id (content ~environment:None same_state)
     <> id (content ~environment:(Some "prod") same_state))
;;

(* BUG-026: every input the renderer turns into manifest content must move the
   identity. Each of these was previously invisible to it, so a real change kept
   the previous [release] label. *)
let test_manifest_affecting_fields_change_identity () =
  let base = id (content [ wl "charge_svc" "acme/charge:1" ]) in
  let moved label other = check_bool label true (base <> id (content [ other ])) in
  moved
    "volume change"
    (wl
       ~volumes:[ "data", "/data", "1Gi", "read_write_once" ]
       "charge_svc"
       "acme/charge:1");
  moved "rollout change" (wl ~rollout:"recreate" "charge_svc" "acme/charge:1");
  moved "canary steps change" (wl ~rollout:"canary:w10,w100" "charge_svc" "acme/charge:1");
  moved
    "ingress host change"
    (wl ~ingress_host:(Some "charge.example.com") "charge_svc" "acme/charge:1");
  moved
    "ingress path change"
    (wl ~ingress_path:(Some "/api") "charge_svc" "acme/charge:1");
  moved
    "cluster issuer change"
    (wl ~cluster_issuer:"other-issuer" "charge_svc" "acme/charge:1");
  moved
    "service call change"
    (wl ~calls:[ "X_URL", "x", "x-svc", "ns-x" ] "charge_svc" "acme/charge:1")
;;

(* A canary's step *sequence* is the strategy, so it is semantic — unlike the
   set-like tables below. *)
let test_canary_step_order_is_semantic () =
  check_bool
    "canary step order changes identity"
    true
    (id (content [ wl ~rollout:"canary:w10,w100" "charge_svc" "acme/charge:1" ])
     <> id (content [ wl ~rollout:"canary:w100,w10" "charge_svc" "acme/charge:1" ]))
;;

(* Volume and call order is not semantic, so it must be canonicalised away. *)
let test_volume_and_call_order_is_not_semantic () =
  let v1 = "a", "/a", "1Gi", "read_write_once"
  and v2 = "b", "/b", "2Gi", "read_only_many" in
  check_string
    "volume order does not change identity"
    (id (content [ wl ~volumes:[ v1; v2 ] "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~volumes:[ v2; v1 ] "charge_svc" "acme/charge:1" ]));
  let c1 = "A_URL", "a", "a-svc", "ns-a"
  and c2 = "B_URL", "b", "b-svc", "ns-b" in
  check_string
    "call order does not change identity"
    (id (content [ wl ~calls:[ c1; c2 ] "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~calls:[ c2; c1 ] "charge_svc" "acme/charge:1" ]))
;;

let () =
  Alcotest.run
    "release_id"
    [ ( "identity"
      , [ Alcotest.test_case "deterministic" `Quick test_deterministic
        ; Alcotest.test_case
            "workload order is not semantic"
            `Quick
            test_workload_order_is_not_semantic
        ; Alcotest.test_case
            "config key order is not semantic"
            `Quick
            test_config_key_order_is_not_semantic
        ; Alcotest.test_case
            "secret reference order is not semantic"
            `Quick
            test_secret_reference_order_is_not_semantic
        ; Alcotest.test_case
            "extra label order is not semantic"
            `Quick
            test_extra_label_order_is_not_semantic
        ; Alcotest.test_case
            "image change changes identity"
            `Quick
            test_image_change_changes_identity
        ; Alcotest.test_case
            "scaling change changes identity"
            `Quick
            test_scaling_change_changes_identity
        ; Alcotest.test_case
            "config value change changes identity"
            `Quick
            test_config_value_change_changes_identity
        ; Alcotest.test_case
            "workspace and environment change identity"
            `Quick
            test_workspace_and_environment_change_identity
        ; Alcotest.test_case
            "secret references count, values do not"
            `Quick
            test_secret_references_count_and_values_do_not
        ; Alcotest.test_case "encoding is unambiguous" `Quick test_encoding_is_unambiguous
        ; Alcotest.test_case "known vector" `Quick test_known_vector
        ; Alcotest.test_case
            "environment identity counts, not just resolved state"
            `Quick
            test_environment_identity_counts_not_just_resolved_state
        ; Alcotest.test_case
            "manifest-affecting fields change identity"
            `Quick
            test_manifest_affecting_fields_change_identity
        ; Alcotest.test_case
            "canary step order is semantic"
            `Quick
            test_canary_step_order_is_semantic
        ; Alcotest.test_case
            "volume and call order is not semantic"
            `Quick
            test_volume_and_call_order_is_not_semantic
        ] )
    ; ( "value"
      , [ Alcotest.test_case
            "id is a legal label value"
            `Quick
            test_id_is_a_legal_label_value
        ; Alcotest.test_case
            "of_string round trips and validates"
            `Quick
            test_of_string_round_trips_and_validates
        ] )
    ]
;;
