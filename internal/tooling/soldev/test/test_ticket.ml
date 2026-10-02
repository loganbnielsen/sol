let check_string msg expected actual = Alcotest.(check string) msg expected actual

let check_list_string msg expected actual =
  Alcotest.(check (list string)) msg expected actual
;;

let check_option_string msg expected actual =
  Alcotest.(check (option string)) msg expected actual
;;

let check_bool msg expected actual = Alcotest.(check bool) msg expected actual

let contains_substring ~needle haystack =
  let nl = String.length needle
  and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0
;;

let ticket_state =
  Alcotest.testable
    (fun fmt state -> Format.pp_print_string fmt (Soldev_ticket.state_to_dir state))
    ( = )
;;

let check_state_option msg expected actual =
  Alcotest.(check (option ticket_state)) msg expected actual
;;

let test_parse_empty () =
  let fm = Soldev_ticket.fields "no frontmatter here" in
  Alcotest.(check (list (pair string string))) "empty" [] fm
;;

let test_parse_basic () =
  let content = "---\nid: FEAT-001\ntype: feature\nseverity: high\n---\n\nBody" in
  let fm = Soldev_ticket.fields content in
  check_option_string "id" (Some "FEAT-001") (Soldev_ticket.fm_get fm "id");
  check_option_string "type" (Some "feature") (Soldev_ticket.fm_get fm "type");
  check_option_string "severity" (Some "high") (Soldev_ticket.fm_get fm "severity")
;;

let test_fm_get_missing () =
  let fm = Soldev_ticket.fields "---\nid: X-1\n---\n" in
  check_option_string "missing key" None (Soldev_ticket.fm_get fm "branch")
;;

let test_fm_get_colon_in_value () =
  let content = "---\nurl: https://example.com/path\n---\n" in
  let fm = Soldev_ticket.fields content in
  check_option_string
    "colon in value"
    (Some "https://example.com/path")
    (Soldev_ticket.fm_get fm "url")
;;

let test_depends_none () =
  let content = "---\nid: X\n---\n\n**Depends on:** None.\n" in
  check_list_string "none" [] (Soldev_ticket.parse_depends content)
;;

let test_depends_single () =
  let content = "---\nid: X\n---\n\n**Depends on:** FEAT-001.\n" in
  check_list_string "single" [ "FEAT-001" ] (Soldev_ticket.parse_depends content)
;;

let test_depends_multiple () =
  let content = "---\nid: X\n---\n\n**Depends on:** FEAT-001, EXP-008.\n" in
  check_list_string
    "multiple"
    [ "FEAT-001"; "EXP-008" ]
    (Soldev_ticket.parse_depends content)
;;

let test_depends_missing () =
  let content = "---\nid: X\n---\n\nNo depends line.\n" in
  check_list_string "missing" [] (Soldev_ticket.parse_depends content)
;;

let test_depends_annotated_single () =
  let content =
    "---\n\
     id: X\n\
     ---\n\n\
     **Depends on:** FEAT-033 (done — merged as the evidence base for this ticket).\n"
  in
  check_list_string
    "annotated single"
    [ "FEAT-033" ]
    (Soldev_ticket.parse_depends content)
;;

let test_depends_annotated_multiple () =
  let content =
    "---\nid: X\n---\n\n**Depends on:** FEAT-034 (done), FEAT-035 (done).\n"
  in
  check_list_string
    "annotated multiple"
    [ "FEAT-034"; "FEAT-035" ]
    (Soldev_ticket.parse_depends content)
;;

let test_depends_prose () =
  let content =
    "---\n\
     id: X\n\
     ---\n\n\
     **Depends on:** FEAT-034 in practice — the natural trigger for this ticket is \
     FEAT-034 actually getting built. Not a hard code dependency.\n"
  in
  check_list_string
    "prose, repeated id deduped"
    [ "FEAT-034" ]
    (Soldev_ticket.parse_depends content)
;;

let test_depends_none_with_parenthetical () =
  let content =
    "---\n\
     id: X\n\
     ---\n\n\
     **Depends on:** None. (BUG-008's port-shadowing fix already unblocked local access.)\n"
  in
  check_list_string
    "none with parenthetical, aside is not a dependency"
    []
    (Soldev_ticket.parse_depends content)
;;

let test_depends_underscore_prefix () =
  let content = "---\nid: X\n---\n\n**Depends on:** CODEX_STYLE_AUDIT-006.\n" in
  check_list_string
    "underscore prefix"
    [ "CODEX_STYLE_AUDIT-006" ]
    (Soldev_ticket.parse_depends content)
;;

let test_no_gate () =
  let content = "---\nid: X\n---\n\nJust a ticket body.\n" in
  check_bool "no gate" false (Soldev_ticket.has_human_decision_gate content)
;;

let test_gate_tbd () =
  let content = "---\nid: X\n---\n\nSomething TBD here.\n" in
  check_bool "TBD gate" true (Soldev_ticket.has_human_decision_gate content)
;;

let test_gate_section () =
  let content = "---\nid: X\n---\n\n## Decision Required\nChoose A or B.\n" in
  check_bool "section gate" true (Soldev_ticket.has_human_decision_gate content)
;;

let test_title_basic () =
  let content = "---\nid: X\n---\n\n**Depends on:** None.\n\nFix the thing\n" in
  check_string "title" "Fix the thing" (Soldev_ticket.ticket_title content)
;;

let test_title_no_frontmatter () =
  let content = "Just a title line\n\nBody here." in
  check_string "no frontmatter" "Just a title line" (Soldev_ticket.ticket_title content)
;;

let test_title_explicit_field_wins () =
  let content =
    "---\n\
     id: X\n\
     title: Charged twice on retry\n\
     ---\n\n\
     **Depends on:** None.\n\n\
     An opening paragraph that reads like a sentence, not a title.\n"
  in
  check_string
    "explicit title"
    "Charged twice on retry"
    (Soldev_ticket.ticket_title content)
;;

let test_title_strips_heading_markers () =
  let content =
    "---\nid: X\n---\n\n**Depends on:** None.\n\n# Real title here\n\nBody.\n"
  in
  check_string
    "heading markers stripped"
    "Real title here"
    (Soldev_ticket.ticket_title content)
;;

let test_title_skips_any_bold_field () =
  let content =
    "---\n\
     id: X\n\
     ---\n\n\
     **Depends on:** None.\n\n\
     **Related:** DEC-016, FEAT-058.\n\n\
     A prose title sentence.\n"
  in
  check_string
    "a second bold field is skipped too"
    "A prose title sentence."
    (Soldev_ticket.ticket_title content)
;;

let test_title_blank_field_falls_back () =
  let content =
    "---\nid: X\ntitle:  \n---\n\n**Depends on:** None.\n\nFallback title\n"
  in
  check_string
    "a blank title field is not a title"
    "Fallback title"
    (Soldev_ticket.ticket_title content)
;;

let test_dep_summary_empty () =
  check_string "empty" "none" (Soldev_ticket.dependency_summary [])
;;

let test_dep_summary_list () =
  check_string "list" "A, B" (Soldev_ticket.dependency_summary [ "A"; "B" ])
;;

let test_states_include_done () =
  check_bool "DONE present" true (List.mem Soldev_ticket.Done Soldev_ticket.all_states)
;;

let test_states_include_rfe () =
  check_bool
    "READY_FOR_ENGINEERING present"
    true
    (List.mem Soldev_ticket.Ready_for_engineering Soldev_ticket.all_states)
;;

let test_state_roundtrip () =
  List.iter
    (fun state ->
       check_state_option
         ("roundtrip " ^ Soldev_ticket.state_to_dir state)
         (Some state)
         (Soldev_ticket.state_of_dir (Soldev_ticket.state_to_dir state)))
    Soldev_ticket.all_states
;;

let test_state_unknown () =
  check_state_option "unknown" None (Soldev_ticket.state_of_dir "NOPE")
;;

let test_states_no_longer_include_removed_states () =
  check_state_option
    "IN_PROGRESS no longer a state"
    None
    (Soldev_ticket.state_of_dir "IN_PROGRESS");
  check_state_option "REVIEW no longer a state" None (Soldev_ticket.state_of_dir "REVIEW");
  check_state_option
    "READY_TO_MERGE no longer a state"
    None
    (Soldev_ticket.state_of_dir "READY_TO_MERGE");
  check_state_option
    "BLOCKED_BY_PERFORMANCE no longer a state"
    None
    (Soldev_ticket.state_of_dir "BLOCKED_BY_PERFORMANCE");
  check_bool "only 3 states remain" true (List.length Soldev_ticket.all_states = 3)
;;

let test_yaml_quoting_is_decoded () =
  let content =
    "---\n\
     premise: '! rg -q ''let \\( let\\* \\) ='' x'\n\
     title: \"A \\\"quoted\\\" title\"\n\
     ---\n"
  in
  check_option_string
    "a single-quoted probe keeps its backslashes and un-doubles its quotes"
    (Some "! rg -q 'let \\( let\\* \\) =' x")
    (Soldev_ticket.premise_of content);
  check_string
    "a double-quoted escape is decoded"
    "A \"quoted\" title"
    (Soldev_ticket.ticket_title content)
;;

let test_yaml_comment_and_null () =
  let content = "---\nid: X-1  # a comment\nbranch: ~\npr:\n---\n" in
  let fm = Soldev_ticket.fields content in
  check_option_string
    "a comment is not part of the value"
    (Some "X-1")
    (Soldev_ticket.fm_get fm "id");
  check_option_string "null is absent" None (Soldev_ticket.fm_get fm "branch");
  check_option_string "empty is absent" None (Soldev_ticket.fm_get fm "pr")
;;

let test_invalid_frontmatter_is_an_error () =
  match Soldev_ticket.frontmatter "---\nsource: operator: said so\n---\n" with
  | Ok _ -> Alcotest.fail "an invalid frontmatter was accepted"
  | Error message ->
    check_bool "names YAML" true (contains_substring ~needle:"not valid YAML" message)
;;

let test_every_ticket_is_readable () =
  let root = "../../../pipeline/tickets" in
  let failures =
    [ "BACKLOG"; "READY_FOR_ENGINEERING"; "DONE" ]
    |> List.concat_map (fun state ->
      Sys.readdir (Filename.concat root state)
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".md")
      |> List.map (fun f -> Filename.concat (Filename.concat root state) f))
    |> List.filter_map (fun path ->
      let content = In_channel.with_open_bin path In_channel.input_all in
      Soldev_ticket.unreadable ~path content)
  in
  Alcotest.(check (list string))
    "every ticket in the pipeline tree is readable"
    []
    failures
;;

let readable_ticket =
  {|---
id: BUG-999
type: bug
severity: low
source: a test
premise: "rg -q 'x' y.ml"
---

Body.
|}
;;

let test_readable () =
  check_option_string
    "a complete ticket is readable"
    None
    (Soldev_ticket.unreadable
       ~path:"internal/pipeline/tickets/BACKLOG/BUG-999.md"
       readable_ticket)
;;

let test_readable_extra_fields () =
  let content = readable_ticket ^ "\nowning_stream: qualification\n" in
  check_option_string
    "extra fields are not policed"
    None
    (Soldev_ticket.unreadable
       ~path:"internal/pipeline/tickets/BACKLOG/BUG-999.md"
       content)
;;

let test_no_frontmatter_block_is_unreadable () =
  let path = "internal/pipeline/tickets/DONE/INFRA-042.md" in
  match
    Soldev_ticket.unreadable ~path "# INFRA-042 - a ticket with no frontmatter\n\nBody.\n"
  with
  | None -> Alcotest.fail "a ticket with no frontmatter block was accepted"
  | Some reason ->
    check_bool "names the file" true (contains_substring ~needle:path reason);
    check_bool
      "says what is missing"
      true
      (contains_substring ~needle:"no frontmatter block" reason)
;;

let test_invalid_yaml_is_unreadable () =
  let path = "internal/pipeline/tickets/READY_FOR_ENGINEERING/FEAT-103.md" in
  let content =
    "---\n\
     id: FEAT-103\n\
     type: feature\n\
     severity: medium\n\
     source: review - \"a colon: in a plain scalar\"\n\
     ---\n\n\
     Body.\n"
  in
  match Soldev_ticket.unreadable ~path content with
  | None -> Alcotest.fail "an invalid frontmatter was accepted"
  | Some reason ->
    check_bool "names the file" true (contains_substring ~needle:path reason);
    check_bool "names YAML" true (contains_substring ~needle:"not valid YAML" reason)
;;

let test_wrapped_depends_is_unreadable () =
  let path = "internal/pipeline/tickets/BACKLOG/BUG-999.md" in
  let content = readable_ticket ^ "\n**Depends on:** DEC-026, SEC-004,\nDEC-027.\n" in
  match Soldev_ticket.unreadable ~path content with
  | None -> Alcotest.fail "a wrapped Depends on field was accepted"
  | Some reason ->
    check_bool "names the file" true (contains_substring ~needle:path reason);
    check_bool "names the field" true (contains_substring ~needle:"Depends on" reason)
;;

let test_one_line_depends_is_readable () =
  check_option_string
    "a one-line field followed by a blank line is readable"
    None
    (Soldev_ticket.unreadable
       ~path:"internal/pipeline/tickets/BACKLOG/BUG-999.md"
       (readable_ticket ^ "\n**Depends on:** DEC-026, DEC-027.\n\nCommentary.\n"))
;;

let test_missing_field_is_unreadable () =
  let path = "internal/pipeline/tickets/BACKLOG/BUG-998.md" in
  let content =
    "---\nid: BUG-998\ntype: bug\nseverity:\nsource: a test\n---\n\nBody.\n"
  in
  match Soldev_ticket.unreadable ~path content with
  | None -> Alcotest.fail "a blank required field was accepted"
  | Some reason ->
    check_bool "names the file" true (contains_substring ~needle:path reason);
    check_bool "names the field" true (contains_substring ~needle:"`severity`" reason)
;;

let test_each_required_field () =
  List.iter
    (fun field ->
       let lines =
         [ "id: BUG-997"; "type: bug"; "severity: low"; "source: a test" ]
         |> List.filter (fun line ->
           not
             (String.length line >= String.length field
              && String.sub line 0 (String.length field) = field))
       in
       let content = "---\n" ^ String.concat "\n" lines ^ "\n---\n\nBody.\n" in
       match Soldev_ticket.unreadable ~path:"x.md" content with
       | None -> Alcotest.fail (Printf.sprintf "a ticket without `%s` was accepted" field)
       | Some reason ->
         check_bool
           (Printf.sprintf "names `%s`" field)
           true
           (contains_substring ~needle:("`" ^ field ^ "`") reason))
    [ "id"; "type"; "severity"; "source" ]
;;

let () =
  Alcotest.run
    "soldev_ticket"
    [ ( "parse_frontmatter"
      , [ Alcotest.test_case "empty content" `Quick test_parse_empty
        ; Alcotest.test_case "basic fields" `Quick test_parse_basic
        ; Alcotest.test_case "missing key" `Quick test_fm_get_missing
        ; Alcotest.test_case "colon in value" `Quick test_fm_get_colon_in_value
        ] )
    ; ( "parse_depends"
      , [ Alcotest.test_case "none" `Quick test_depends_none
        ; Alcotest.test_case "single dep" `Quick test_depends_single
        ; Alcotest.test_case "multiple deps" `Quick test_depends_multiple
        ; Alcotest.test_case "no depends line" `Quick test_depends_missing
        ; Alcotest.test_case "annotated single" `Quick test_depends_annotated_single
        ; Alcotest.test_case "annotated multiple" `Quick test_depends_annotated_multiple
        ; Alcotest.test_case "prose, repeated id" `Quick test_depends_prose
        ; Alcotest.test_case
            "none w/ parenthetical"
            `Quick
            test_depends_none_with_parenthetical
        ; Alcotest.test_case "underscore prefix" `Quick test_depends_underscore_prefix
        ] )
    ; ( "has_human_decision_gate"
      , [ Alcotest.test_case "no gate" `Quick test_no_gate
        ; Alcotest.test_case "TBD marker" `Quick test_gate_tbd
        ; Alcotest.test_case "section marker" `Quick test_gate_section
        ] )
    ; ( "ticket_title"
      , [ Alcotest.test_case "skips depends line" `Quick test_title_basic
        ; Alcotest.test_case "no frontmatter" `Quick test_title_no_frontmatter
        ; Alcotest.test_case
            "explicit title field wins"
            `Quick
            test_title_explicit_field_wins
        ; Alcotest.test_case
            "heading markers stripped"
            `Quick
            test_title_strips_heading_markers
        ; Alcotest.test_case
            "any bold field skipped"
            `Quick
            test_title_skips_any_bold_field
        ; Alcotest.test_case
            "blank title field falls back"
            `Quick
            test_title_blank_field_falls_back
        ] )
    ; ( "dependency_summary"
      , [ Alcotest.test_case "empty" `Quick test_dep_summary_empty
        ; Alcotest.test_case "list" `Quick test_dep_summary_list
        ] )
    ; ( "ticket states"
      , [ Alcotest.test_case "includes DONE" `Quick test_states_include_done
        ; Alcotest.test_case "includes RFE" `Quick test_states_include_rfe
        ; Alcotest.test_case "state roundtrip" `Quick test_state_roundtrip
        ; Alcotest.test_case "unknown state" `Quick test_state_unknown
        ; Alcotest.test_case
            "removed states gone"
            `Quick
            test_states_no_longer_include_removed_states
        ] )
    ; ( "frontmatter is YAML (REFAC-137)"
      , [ Alcotest.test_case "quoting is decoded" `Quick test_yaml_quoting_is_decoded
        ; Alcotest.test_case "comments and null" `Quick test_yaml_comment_and_null
        ; Alcotest.test_case
            "invalid frontmatter is an error"
            `Quick
            test_invalid_frontmatter_is_an_error
        ; Alcotest.test_case "every ticket parses" `Quick test_every_ticket_is_readable
        ] )
    ; ( "unreadable tickets fail closed (BUG-060)"
      , [ Alcotest.test_case "a complete ticket" `Quick test_readable
        ; Alcotest.test_case "extra fields are fine" `Quick test_readable_extra_fields
        ; Alcotest.test_case
            "no frontmatter block"
            `Quick
            test_no_frontmatter_block_is_unreadable
        ; Alcotest.test_case "invalid YAML" `Quick test_invalid_yaml_is_unreadable
        ; Alcotest.test_case
            "wrapped Depends on"
            `Quick
            test_wrapped_depends_is_unreadable
        ; Alcotest.test_case
            "one-line Depends on"
            `Quick
            test_one_line_depends_is_readable
        ; Alcotest.test_case "a blank field" `Quick test_missing_field_is_unreadable
        ; Alcotest.test_case "each required field" `Quick test_each_required_field
        ] )
    ; ( "dependency cycles"
      , [ Alcotest.test_case "self cycle" `Quick (fun () ->
            Alcotest.(check (option (list string)))
              "a ticket depending on itself is a cycle"
              (Some [ "A-1"; "A-1" ])
              (Soldev_ticket.find_dependency_cycle_from
                 ~deps_of:(fun id -> if String.equal id "A-1" then [ "A-1" ] else [])
                 "A-1"))
        ; Alcotest.test_case "mutual cycle" `Quick (fun () ->
            let deps_of = function
              | "A-1" -> [ "B-2" ]
              | "B-2" -> [ "A-1" ]
              | _ -> []
            in
            Alcotest.(check (option (list string)))
              "each names the other"
              (Some [ "A-1"; "B-2"; "A-1" ])
              (Soldev_ticket.find_dependency_cycle_from ~deps_of "A-1"))
        ; Alcotest.test_case "cycle reached from outside" `Quick (fun () ->
            let deps_of = function
              | "X-9" -> [ "A-1" ]
              | "A-1" -> [ "B-2" ]
              | "B-2" -> [ "A-1" ]
              | _ -> []
            in
            Alcotest.(check (option (list string)))
              "reports the cycle and not the path taken to reach it"
              (Some [ "A-1"; "B-2"; "A-1" ])
              (Soldev_ticket.find_dependency_cycle_from ~deps_of "X-9"))
        ; Alcotest.test_case "no cycle" `Quick (fun () ->
            let deps_of = function
              | "A-1" -> [ "B-2" ]
              | "B-2" -> [ "C-3" ]
              | _ -> []
            in
            Alcotest.(check (option (list string)))
              "a chain is not a cycle"
              None
              (Soldev_ticket.find_dependency_cycle_from ~deps_of "A-1"))
        ; Alcotest.test_case "shared dependency is not a cycle" `Quick (fun () ->
            let deps_of = function
              | "A-1" -> [ "B-2"; "C-3" ]
              | "B-2" -> [ "C-3" ]
              | _ -> []
            in
            Alcotest.(check (option (list string)))
              "a diamond is not a cycle"
              None
              (Soldev_ticket.find_dependency_cycle_from ~deps_of "A-1"))
        ] )
    ; ( "premise probes"
      , [ Alcotest.test_case "declared probe is read" `Quick (fun () ->
            let content = "---\nid: X\npremise: \"rg -q foo bar.ml\"\n---\n\nBody\n" in
            Alcotest.(check (option string))
              "probe, with the documented quoting stripped"
              (Some "rg -q foo bar.ml")
              (Soldev_ticket.premise_of content))
        ; Alcotest.test_case "unquoted probe is read too" `Quick (fun () ->
            let content = "---\nid: X\npremise: rg -q foo bar.ml\n---\n\nBody\n" in
            Alcotest.(check (option string))
              "probe"
              (Some "rg -q foo bar.ml")
              (Soldev_ticket.premise_of content))
        ; Alcotest.test_case "no probe" `Quick (fun () ->
            Alcotest.(check (option string))
              "none"
              None
              (Soldev_ticket.premise_of "---\nid: X\n---\n\nBody\n"))
        ; Alcotest.test_case "blank probe is no probe" `Quick (fun () ->
            Alcotest.(check (option string))
              "none"
              None
              (Soldev_ticket.premise_of "---\nid: X\npremise: \"  \"\n---\n\nBody\n"))
        ; Alcotest.test_case "exit 0 means stale" `Quick (fun () ->
            match Soldev_ticket.premise_verdict ~exit_code:0 with
            | Soldev_ticket.Premise_stale -> ()
            | Soldev_ticket.Premise_holds -> Alcotest.fail "exit 0 must mean stale"
            | Soldev_ticket.Premise_unverified reason ->
              Alcotest.fail ("unexpected unverified: " ^ reason))
        ; Alcotest.test_case "non-zero means the premise holds" `Quick (fun () ->
            match Soldev_ticket.premise_verdict ~exit_code:1 with
            | Soldev_ticket.Premise_holds -> ()
            | _ -> Alcotest.fail "a failing probe means the premise still holds")
        ; Alcotest.test_case "127 is unverified, not holds" `Quick (fun () ->
            match Soldev_ticket.premise_verdict ~exit_code:127 with
            | Soldev_ticket.Premise_unverified _ -> ()
            | _ -> Alcotest.fail "a probe that cannot run must not read as holds")
        ] )
    ]
;;
