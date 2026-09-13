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
      ?(cpu = "100m")
      ?(memory = "128Mi")
      ?(extra_labels = [])
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
  ; cpu
  ; memory
  ; extra_labels
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
     let contains needle =
       let n = String.length needle
       and h = String.length s in
       let rec loop i =
         if i + n > h
         then false
         else if String.sub s i n = needle
         then true
         else loop (i + 1)
       in
       loop 0
     in
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
    "r-f4db347c7c7a2d1b"
    (id
       (content
          [ wl
              ~config:[ "LOG_LEVEL", "info" ]
              ~secrets:[ "DATABASE_URL", "db-prod" ]
              "charge_svc"
              "acme/charge:1"
          ]))
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
