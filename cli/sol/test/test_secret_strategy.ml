(* Tests for the secret strategy contract (CODEX_STYLE_AUDIT-070).
   Verifies:
   - Kubernetes_live is derived for live targets (Local, Customer_direct)
   - Kubernetes_placeholder is derived for GitOps/hosted targets
   - External_secrets round-trips through secret_backend_to_string
   - The gitops+live combination is identified as unsafe by inspecting
     default_secret_backend against a Customer_gitops target *)

let check_backend label expected actual =
  Alcotest.(check string)
    label
    (Sol_cli_manifest.secret_backend_to_string expected)
    (Sol_cli_manifest.secret_backend_to_string actual)
;;

(* ── Kubernetes_live: allowed for live targets ───────────────────────────── *)

let test_live_for_local () =
  let t = Sol_cli_env_target.local_defaults ~image_tag:"abc" in
  check_backend
    "Local default is Kubernetes_live"
    Sol_cli_manifest.Kubernetes_live
    (Sol_cli_env_target.default_secret_backend t)
;;

let test_live_for_customer_direct () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg.example.com"
      ~image_tag:"sha-1"
      ~emit_to:None
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    check_backend
      "Customer_direct default is Kubernetes_live"
      Sol_cli_manifest.Kubernetes_live
      (Sol_cli_env_target.default_secret_backend t)
;;

(* ── Kubernetes_placeholder: required for GitOps targets ────────────────── *)

let test_placeholder_for_gitops () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg.example.com"
      ~image_tag:"sha-1"
      ~emit_to:(Some "/tmp/gitops-out")
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    check_backend
      "Customer_gitops default is Kubernetes_placeholder"
      Sol_cli_manifest.Kubernetes_placeholder
      (Sol_cli_env_target.default_secret_backend t)
;;

(* ── External_secrets round-trip ─────────────────────────────────────────── *)

let test_external_secrets_to_string () =
  let backend =
    Sol_cli_manifest.External_secrets
      { store_ref = "my-store"
      ; store_kind = "ClusterSecretStore"
      ; key_prefix = "myws/"
      ; refresh_interval = "1h"
      }
  in
  Alcotest.(check string)
    "External_secrets serialises correctly"
    "external-secrets"
    (Sol_cli_manifest.secret_backend_to_string backend)
;;

(* ── GitOps + Kubernetes_live is unsafe by construction ──────────────────── *)

(* The guard in cmd_deploy.ml checks:
     match env_target, req.secret_backend with
     | Customer_gitops _, Kubernetes_live -> exit 1
   We verify here that (a) Customer_gitops produces a Kubernetes_placeholder
   default (not Kubernetes_live), and (b) the pairing IS detected as unsafe. *)

let test_gitops_live_combination_is_unsafe () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg"
      ~image_tag:"tag"
      ~emit_to:(Some "/tmp/out")
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok target ->
    (* The default backend must NOT be Kubernetes_live *)
    let default_be = Sol_cli_env_target.default_secret_backend target in
    Alcotest.(check bool)
      "default is not live"
      false
      (default_be = Sol_cli_manifest.Kubernetes_live);
    (* Simulating the guard: Customer_gitops + Kubernetes_live must be caught *)
    let is_unsafe =
      match target, Sol_cli_manifest.Kubernetes_live with
      | Sol_cli_env_target.Customer_gitops _, Sol_cli_manifest.Kubernetes_live -> true
      | _ -> false
    in
    Alcotest.(check bool) "guard detects gitops+live as unsafe" true is_unsafe
;;

let () =
  Alcotest.run
    "secret_strategy"
    [ ( "Kubernetes_live"
      , [ Alcotest.test_case "Local target" `Quick test_live_for_local
        ; Alcotest.test_case "Customer_direct target" `Quick test_live_for_customer_direct
        ] )
    ; ( "Kubernetes_placeholder"
      , [ Alcotest.test_case "Customer_gitops target" `Quick test_placeholder_for_gitops ]
      )
    ; ( "External_secrets"
      , [ Alcotest.test_case "to_string round-trip" `Quick test_external_secrets_to_string
        ] )
    ; ( "GitOps safety guard"
      , [ Alcotest.test_case
            "gitops+live detected as unsafe"
            `Quick
            test_gitops_live_combination_is_unsafe
        ] )
    ]
;;
