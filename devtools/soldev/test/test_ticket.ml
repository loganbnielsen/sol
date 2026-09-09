let check_string msg expected actual =
  Alcotest.(check string) msg expected actual

let check_list_string msg expected actual =
  Alcotest.(check (list string)) msg expected actual

let check_option_string msg expected actual =
  Alcotest.(check (option string)) msg expected actual

let check_bool msg expected actual =
  Alcotest.(check bool) msg expected actual

let contains_substring ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let ticket_state =
  Alcotest.testable
    (fun fmt state -> Format.pp_print_string fmt (Soldev_ticket.state_to_dir state))
    (=)

let check_state_option msg expected actual =
  Alcotest.(check (option ticket_state)) msg expected actual

let review_status =
  Alcotest.testable
    (fun fmt status ->
       Format.pp_print_string fmt (Soldev_ticket.review_status_to_string status))
    (=)

let check_review_status_option msg expected actual =
  Alcotest.(check (option review_status)) msg expected actual

(* ── parse_frontmatter ───────────────────────────────────────────────────── *)

let test_parse_empty () =
  let fm = Soldev_ticket.parse_frontmatter "no frontmatter here" in
  Alcotest.(check (list (pair string string))) "empty" [] fm

let test_parse_basic () =
  let content = "---\nid: FEAT-001\ntype: feature\nseverity: high\n---\n\nBody" in
  let fm = Soldev_ticket.parse_frontmatter content in
  check_option_string "id"       (Some "FEAT-001") (Soldev_ticket.fm_get fm "id");
  check_option_string "type"     (Some "feature")  (Soldev_ticket.fm_get fm "type");
  check_option_string "severity" (Some "high")     (Soldev_ticket.fm_get fm "severity")

let test_fm_get_missing () =
  let fm = Soldev_ticket.parse_frontmatter "---\nid: X-1\n---\n" in
  check_option_string "missing key" None (Soldev_ticket.fm_get fm "branch")

let test_fm_get_colon_in_value () =
  let content = "---\nurl: https://example.com/path\n---\n" in
  let fm = Soldev_ticket.parse_frontmatter content in
  check_option_string "colon in value"
    (Some "https://example.com/path") (Soldev_ticket.fm_get fm "url")

(* ── parse_depends ───────────────────────────────────────────────────────── *)

let test_depends_none () =
  let content = "---\nid: X\n---\n\n**Depends on:** None.\n" in
  check_list_string "none" [] (Soldev_ticket.parse_depends content)

let test_depends_single () =
  let content = "---\nid: X\n---\n\n**Depends on:** FEAT-001.\n" in
  check_list_string "single" ["FEAT-001"] (Soldev_ticket.parse_depends content)

let test_depends_multiple () =
  let content = "---\nid: X\n---\n\n**Depends on:** FEAT-001, EXP-008.\n" in
  check_list_string "multiple" ["FEAT-001"; "EXP-008"] (Soldev_ticket.parse_depends content)

let test_depends_missing () =
  let content = "---\nid: X\n---\n\nNo depends line.\n" in
  check_list_string "missing" [] (Soldev_ticket.parse_depends content)

let test_depends_annotated_single () =
  let content =
    "---\nid: X\n---\n\n**Depends on:** FEAT-033 (done — merged as the evidence base for this ticket).\n"
  in
  check_list_string "annotated single" ["FEAT-033"] (Soldev_ticket.parse_depends content)

let test_depends_annotated_multiple () =
  let content =
    "---\nid: X\n---\n\n**Depends on:** FEAT-034 (done), FEAT-035 (done).\n"
  in
  check_list_string "annotated multiple" ["FEAT-034"; "FEAT-035"]
    (Soldev_ticket.parse_depends content)

let test_depends_prose () =
  let content =
    "---\nid: X\n---\n\n**Depends on:** FEAT-034 in practice — the natural trigger for this ticket is FEAT-034 actually getting built. Not a hard code dependency.\n"
  in
  check_list_string "prose, repeated id" ["FEAT-034"; "FEAT-034"]
    (Soldev_ticket.parse_depends content)

let test_depends_none_with_parenthetical () =
  let content =
    "---\nid: X\n---\n\n**Depends on:** None. (BUG-008's port-shadowing fix already unblocked local access.)\n"
  in
  check_list_string "none with parenthetical, aside is not a dependency" []
    (Soldev_ticket.parse_depends content)

let test_depends_underscore_prefix () =
  let content =
    "---\nid: X\n---\n\n**Depends on:** CODEX_STYLE_AUDIT-006.\n"
  in
  check_list_string "underscore prefix" ["CODEX_STYLE_AUDIT-006"]
    (Soldev_ticket.parse_depends content)

(* ── has_human_decision_gate ─────────────────────────────────────────────── *)

let test_no_gate () =
  let content = "---\nid: X\n---\n\nJust a ticket body.\n" in
  check_bool "no gate" false (Soldev_ticket.has_human_decision_gate content)

let test_gate_tbd () =
  let content = "---\nid: X\n---\n\nSomething TBD here.\n" in
  check_bool "TBD gate" true (Soldev_ticket.has_human_decision_gate content)

let test_gate_section () =
  let content = "---\nid: X\n---\n\n## Decision Required\nChoose A or B.\n" in
  check_bool "section gate" true (Soldev_ticket.has_human_decision_gate content)

(* ── ticket_title ────────────────────────────────────────────────────────── *)

let test_title_basic () =
  let content = "---\nid: X\n---\n\n**Depends on:** None.\n\nFix the thing\n" in
  check_string "title" "Fix the thing" (Soldev_ticket.ticket_title content)

let test_title_no_frontmatter () =
  let content = "Just a title line\n\nBody here." in
  check_string "no frontmatter" "Just a title line" (Soldev_ticket.ticket_title content)

(* ── dependency_summary ──────────────────────────────────────────────────── *)

let test_dep_summary_empty () =
  check_string "empty" "none" (Soldev_ticket.dependency_summary [])

let test_dep_summary_list () =
  check_string "list" "A, B"
    (Soldev_ticket.dependency_summary ["A"; "B"])

(* ── ticket states ───────────────────────────────────────────────────────── *)

let test_states_include_done () =
  check_bool "DONE present" true
    (List.mem Soldev_ticket.Done Soldev_ticket.all_states)

let test_states_include_rfe () =
  check_bool "READY_FOR_ENGINEERING present" true
    (List.mem Soldev_ticket.Ready_for_engineering Soldev_ticket.all_states)

let test_state_roundtrip () =
  List.iter (fun state ->
    check_state_option
      ("roundtrip " ^ Soldev_ticket.state_to_dir state)
      (Some state)
      (Soldev_ticket.state_of_dir (Soldev_ticket.state_to_dir state))
  ) Soldev_ticket.all_states

let test_state_unknown () =
  check_state_option "unknown" None (Soldev_ticket.state_of_dir "NOPE")

let test_review_status_roundtrip () =
  check_review_status_option "pass" (Some Soldev_ticket.Pass)
    (Soldev_ticket.review_status_of_string "pass");
  check_review_status_option "fail" (Some Soldev_ticket.Fail)
    (Soldev_ticket.review_status_of_string "fail");
  check_string "pass string" "pass"
    (Soldev_ticket.review_status_to_string Soldev_ticket.Pass);
  check_string "fail string" "fail"
    (Soldev_ticket.review_status_to_string Soldev_ticket.Fail)

let test_review_status_unknown () =
  check_review_status_option "unknown" None
    (Soldev_ticket.review_status_of_string "maybe")

(* ── set_frontmatter_field ───────────────────────────────────────────────── *)

let test_set_field_appends_when_absent () =
  let content = "---\nid: FEAT-001\ntype: feature\n---\n\nBody" in
  let updated = Soldev_ticket.set_frontmatter_field content "pr" "https://github.com/x/y/pull/1" in
  let fm = Soldev_ticket.parse_frontmatter updated in
  check_option_string "pr added" (Some "https://github.com/x/y/pull/1") (Soldev_ticket.fm_get fm "pr");
  check_option_string "id preserved" (Some "FEAT-001") (Soldev_ticket.fm_get fm "id");
  check_bool "body preserved" true (contains_substring ~needle:"Body" updated)

let test_set_field_overwrites_when_present () =
  let content = "---\nid: FEAT-001\npr: https://old\n---\n\nBody" in
  let updated = Soldev_ticket.set_frontmatter_field content "pr" "https://new" in
  let fm = Soldev_ticket.parse_frontmatter updated in
  check_option_string "pr overwritten" (Some "https://new") (Soldev_ticket.fm_get fm "pr")

let test_set_field_no_frontmatter_is_noop () =
  let content = "no frontmatter here" in
  check_string "unchanged" content (Soldev_ticket.set_frontmatter_field content "pr" "https://x")

let () =
  Alcotest.run "soldev_ticket" [
    "parse_frontmatter", [
      Alcotest.test_case "empty content"         `Quick test_parse_empty;
      Alcotest.test_case "basic fields"          `Quick test_parse_basic;
      Alcotest.test_case "missing key"           `Quick test_fm_get_missing;
      Alcotest.test_case "colon in value"        `Quick test_fm_get_colon_in_value;
    ];
    "parse_depends", [
      Alcotest.test_case "none"                  `Quick test_depends_none;
      Alcotest.test_case "single dep"            `Quick test_depends_single;
      Alcotest.test_case "multiple deps"         `Quick test_depends_multiple;
      Alcotest.test_case "no depends line"       `Quick test_depends_missing;
      Alcotest.test_case "annotated single"      `Quick test_depends_annotated_single;
      Alcotest.test_case "annotated multiple"    `Quick test_depends_annotated_multiple;
      Alcotest.test_case "prose, repeated id"    `Quick test_depends_prose;
      Alcotest.test_case "none w/ parenthetical" `Quick test_depends_none_with_parenthetical;
      Alcotest.test_case "underscore prefix"     `Quick test_depends_underscore_prefix;
    ];
    "has_human_decision_gate", [
      Alcotest.test_case "no gate"               `Quick test_no_gate;
      Alcotest.test_case "TBD marker"            `Quick test_gate_tbd;
      Alcotest.test_case "section marker"        `Quick test_gate_section;
    ];
    "ticket_title", [
      Alcotest.test_case "skips depends line"    `Quick test_title_basic;
      Alcotest.test_case "no frontmatter"        `Quick test_title_no_frontmatter;
    ];
    "dependency_summary", [
      Alcotest.test_case "empty"                 `Quick test_dep_summary_empty;
      Alcotest.test_case "list"                  `Quick test_dep_summary_list;
    ];
    "ticket states", [
      Alcotest.test_case "includes DONE"         `Quick test_states_include_done;
      Alcotest.test_case "includes RFE"          `Quick test_states_include_rfe;
      Alcotest.test_case "state roundtrip"       `Quick test_state_roundtrip;
      Alcotest.test_case "unknown state"         `Quick test_state_unknown;
    ];
    "review_status", [
      Alcotest.test_case "roundtrip"             `Quick test_review_status_roundtrip;
      Alcotest.test_case "unknown"               `Quick test_review_status_unknown;
    ];
    "set_frontmatter_field", [
      Alcotest.test_case "appends when absent"   `Quick test_set_field_appends_when_absent;
      Alcotest.test_case "overwrites when present" `Quick test_set_field_overwrites_when_present;
      Alcotest.test_case "no frontmatter is noop" `Quick test_set_field_no_frontmatter_is_noop;
    ];
  ]
