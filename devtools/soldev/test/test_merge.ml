let check_string msg expected actual =
  Alcotest.(check string) msg expected actual

let check_option_string msg expected actual =
  Alcotest.(check (option string)) msg expected actual

let test_extract_reverted_branch_match () =
  check_option_string "extracts branch"
    (Some "EXP-023/cloud-init-kubeconfig")
    (Soldev_merge.extract_reverted_branch
       "Revert \"Merge branch 'EXP-023/cloud-init-kubeconfig'\"")

let test_extract_reverted_branch_no_match () =
  check_option_string "unrelated subject" None
    (Soldev_merge.extract_reverted_branch "EXP-023: cloud init kubeconfig")

let test_ticket_id_from_branch_with_slash () =
  check_string "takes prefix before slash"
    "EXP-023"
    (Soldev_merge.ticket_id_from_branch "EXP-023/cloud-init-kubeconfig")

let test_ticket_id_from_branch_no_slash () =
  check_string "whole string when no slash"
    "EXP-023"
    (Soldev_merge.ticket_id_from_branch "EXP-023")

let check_bool msg expected actual = Alcotest.(check bool) msg expected actual

let test_mentions_id_exact () =
  check_bool "exact token match" true
    (Soldev_merge.mentions_id ~id:"AUDIT-023" "abc123 Reapply \"Merge branch 'AUDIT-023/foo'\"")

let test_mentions_id_no_match () =
  check_bool "absent id" false
    (Soldev_merge.mentions_id ~id:"AUDIT-023" "abc123 unrelated commit")

let test_mentions_id_rejects_prefix_embedding () =
  check_bool "AUDIT-023 must not match inside CODEX_STYLE_AUDIT-023" false
    (Soldev_merge.mentions_id ~id:"AUDIT-023" "abc123 Revert \"Merge branch 'CODEX_STYLE_AUDIT-023/x'\"")

let test_mentions_id_rejects_numeric_suffix () =
  check_bool "AUDIT-2 must not match inside AUDIT-23" false
    (Soldev_merge.mentions_id ~id:"AUDIT-2" "abc123 fix AUDIT-23 typo")

let () =
  Alcotest.run "soldev_merge" [
    "extract_reverted_branch", [
      Alcotest.test_case "matches revert-merge subject" `Quick test_extract_reverted_branch_match;
      Alcotest.test_case "ignores unrelated subject"     `Quick test_extract_reverted_branch_no_match;
    ];
    "ticket_id_from_branch", [
      Alcotest.test_case "strips slash suffix" `Quick test_ticket_id_from_branch_with_slash;
      Alcotest.test_case "passes through when no slash" `Quick test_ticket_id_from_branch_no_slash;
    ];
    "mentions_id", [
      Alcotest.test_case "exact token match"       `Quick test_mentions_id_exact;
      Alcotest.test_case "no match"                `Quick test_mentions_id_no_match;
      Alcotest.test_case "rejects prefix embedding" `Quick test_mentions_id_rejects_prefix_embedding;
      Alcotest.test_case "rejects numeric suffix"   `Quick test_mentions_id_rejects_numeric_suffix;
    ];
  ]
