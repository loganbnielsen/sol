let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let check_list_string msg expected actual =
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg expected actual
;;

let check_option_string msg expected actual =
  Windtrap.equal (Windtrap.option Windtrap.string) ~msg expected actual
;;

let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let ticket_state =
  Windtrap.testable
    ~pp:(fun fmt state -> Format.pp_print_string fmt (Soldev_ticket.state_to_dir state))
    ()
;;

let check_state_option msg expected actual =
  Windtrap.equal (Windtrap.option ticket_state) ~msg expected actual
;;

let test_parse_empty () =
  let fm = Soldev_ticket.fields "no frontmatter here" in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"empty"
    []
    fm
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
  | Ok _ -> Windtrap.fail "an invalid frontmatter was accepted"
  | Error message ->
    check_bool
      "names YAML"
      true
      (Soldev_string.contains_substring ~needle:"not valid YAML" message)
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
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"every ticket in the pipeline tree is readable"
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
  | None -> Windtrap.fail "a ticket with no frontmatter block was accepted"
  | Some reason ->
    check_bool
      "names the file"
      true
      (Soldev_string.contains_substring ~needle:path reason);
    check_bool
      "says what is missing"
      true
      (Soldev_string.contains_substring ~needle:"no frontmatter block" reason)
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
  | None -> Windtrap.fail "an invalid frontmatter was accepted"
  | Some reason ->
    check_bool
      "names the file"
      true
      (Soldev_string.contains_substring ~needle:path reason);
    check_bool
      "names YAML"
      true
      (Soldev_string.contains_substring ~needle:"not valid YAML" reason)
;;

let test_wrapped_depends_is_unreadable () =
  let path = "internal/pipeline/tickets/BACKLOG/BUG-999.md" in
  let content = readable_ticket ^ "\n**Depends on:** DEC-026, SEC-004,\nDEC-027.\n" in
  match Soldev_ticket.unreadable ~path content with
  | None -> Windtrap.fail "a wrapped Depends on field was accepted"
  | Some reason ->
    check_bool
      "names the file"
      true
      (Soldev_string.contains_substring ~needle:path reason);
    check_bool
      "names the field"
      true
      (Soldev_string.contains_substring ~needle:"Depends on" reason)
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
  | None -> Windtrap.fail "a blank required field was accepted"
  | Some reason ->
    check_bool
      "names the file"
      true
      (Soldev_string.contains_substring ~needle:path reason);
    check_bool
      "names the field"
      true
      (Soldev_string.contains_substring ~needle:"`severity`" reason)
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
       | None -> Windtrap.fail (Printf.sprintf "a ticket without `%s` was accepted" field)
       | Some reason ->
         check_bool
           (Printf.sprintf "names `%s`" field)
           true
           (Soldev_string.contains_substring ~needle:("`" ^ field ^ "`") reason))
    [ "id"; "type"; "severity"; "source" ]
;;

let () =
  Windtrap.run
    "soldev_ticket"
    [ Windtrap.group
        "parse_frontmatter"
        [ Windtrap.test "empty content" test_parse_empty
        ; Windtrap.test "basic fields" test_parse_basic
        ; Windtrap.test "missing key" test_fm_get_missing
        ; Windtrap.test "colon in value" test_fm_get_colon_in_value
        ]
    ; Windtrap.group
        "parse_depends"
        [ Windtrap.test "none" test_depends_none
        ; Windtrap.test "single dep" test_depends_single
        ; Windtrap.test "multiple deps" test_depends_multiple
        ; Windtrap.test "no depends line" test_depends_missing
        ; Windtrap.test "annotated single" test_depends_annotated_single
        ; Windtrap.test "annotated multiple" test_depends_annotated_multiple
        ; Windtrap.test "prose, repeated id" test_depends_prose
        ; Windtrap.test "none w/ parenthetical" test_depends_none_with_parenthetical
        ; Windtrap.test "underscore prefix" test_depends_underscore_prefix
        ]
    ; Windtrap.group
        "has_human_decision_gate"
        [ Windtrap.test "no gate" test_no_gate
        ; Windtrap.test "TBD marker" test_gate_tbd
        ; Windtrap.test "section marker" test_gate_section
        ]
    ; Windtrap.group
        "ticket_title"
        [ Windtrap.test "skips depends line" test_title_basic
        ; Windtrap.test "no frontmatter" test_title_no_frontmatter
        ; Windtrap.test "explicit title field wins" test_title_explicit_field_wins
        ; Windtrap.test "heading markers stripped" test_title_strips_heading_markers
        ; Windtrap.test "any bold field skipped" test_title_skips_any_bold_field
        ; Windtrap.test "blank title field falls back" test_title_blank_field_falls_back
        ]
    ; Windtrap.group
        "dependency_summary"
        [ Windtrap.test "empty" test_dep_summary_empty
        ; Windtrap.test "list" test_dep_summary_list
        ]
    ; Windtrap.group
        "ticket states"
        [ Windtrap.test "includes DONE" test_states_include_done
        ; Windtrap.test "includes RFE" test_states_include_rfe
        ; Windtrap.test "state roundtrip" test_state_roundtrip
        ; Windtrap.test "unknown state" test_state_unknown
        ; Windtrap.test "removed states gone" test_states_no_longer_include_removed_states
        ]
    ; Windtrap.group
        "frontmatter is YAML (REFAC-137)"
        [ Windtrap.test "quoting is decoded" test_yaml_quoting_is_decoded
        ; Windtrap.test "comments and null" test_yaml_comment_and_null
        ; Windtrap.test
            "invalid frontmatter is an error"
            test_invalid_frontmatter_is_an_error
        ; Windtrap.test "every ticket parses" test_every_ticket_is_readable
        ]
    ; Windtrap.group
        "unreadable tickets fail closed (BUG-060)"
        [ Windtrap.test "a complete ticket" test_readable
        ; Windtrap.test "extra fields are fine" test_readable_extra_fields
        ; Windtrap.test "no frontmatter block" test_no_frontmatter_block_is_unreadable
        ; Windtrap.test "invalid YAML" test_invalid_yaml_is_unreadable
        ; Windtrap.test "wrapped Depends on" test_wrapped_depends_is_unreadable
        ; Windtrap.test "one-line Depends on" test_one_line_depends_is_readable
        ; Windtrap.test "a blank field" test_missing_field_is_unreadable
        ; Windtrap.test "each required field" test_each_required_field
        ]
    ; Windtrap.group
        "dependency cycles"
        [ Windtrap.test "self cycle" (fun () ->
            Windtrap.equal
              (Windtrap.option (Windtrap.list Windtrap.string))
              ~msg:"a ticket depending on itself is a cycle"
              (Some [ "A-1"; "A-1" ])
              (Soldev_ticket.find_dependency_cycle_from
                 ~deps_of:(fun id -> if String.equal id "A-1" then [ "A-1" ] else [])
                 "A-1"))
        ; Windtrap.test "mutual cycle" (fun () ->
            let deps_of = function
              | "A-1" -> [ "B-2" ]
              | "B-2" -> [ "A-1" ]
              | _ -> []
            in
            Windtrap.equal
              (Windtrap.option (Windtrap.list Windtrap.string))
              ~msg:"each names the other"
              (Some [ "A-1"; "B-2"; "A-1" ])
              (Soldev_ticket.find_dependency_cycle_from ~deps_of "A-1"))
        ; Windtrap.test "cycle reached from outside" (fun () ->
            let deps_of = function
              | "X-9" -> [ "A-1" ]
              | "A-1" -> [ "B-2" ]
              | "B-2" -> [ "A-1" ]
              | _ -> []
            in
            Windtrap.equal
              (Windtrap.option (Windtrap.list Windtrap.string))
              ~msg:"reports the cycle and not the path taken to reach it"
              (Some [ "A-1"; "B-2"; "A-1" ])
              (Soldev_ticket.find_dependency_cycle_from ~deps_of "X-9"))
        ; Windtrap.test "no cycle" (fun () ->
            let deps_of = function
              | "A-1" -> [ "B-2" ]
              | "B-2" -> [ "C-3" ]
              | _ -> []
            in
            Windtrap.equal
              (Windtrap.option (Windtrap.list Windtrap.string))
              ~msg:"a chain is not a cycle"
              None
              (Soldev_ticket.find_dependency_cycle_from ~deps_of "A-1"))
        ; Windtrap.test "shared dependency is not a cycle" (fun () ->
            let deps_of = function
              | "A-1" -> [ "B-2"; "C-3" ]
              | "B-2" -> [ "C-3" ]
              | _ -> []
            in
            Windtrap.equal
              (Windtrap.option (Windtrap.list Windtrap.string))
              ~msg:"a diamond is not a cycle"
              None
              (Soldev_ticket.find_dependency_cycle_from ~deps_of "A-1"))
        ]
    ; Windtrap.group
        "premise probes"
        [ Windtrap.test "declared probe is read" (fun () ->
            let content = "---\nid: X\npremise: \"rg -q foo bar.ml\"\n---\n\nBody\n" in
            Windtrap.equal
              (Windtrap.option Windtrap.string)
              ~msg:"probe, with the documented quoting stripped"
              (Some "rg -q foo bar.ml")
              (Soldev_ticket.premise_of content))
        ; Windtrap.test "unquoted probe is read too" (fun () ->
            let content = "---\nid: X\npremise: rg -q foo bar.ml\n---\n\nBody\n" in
            Windtrap.equal
              (Windtrap.option Windtrap.string)
              ~msg:"probe"
              (Some "rg -q foo bar.ml")
              (Soldev_ticket.premise_of content))
        ; Windtrap.test "no probe" (fun () ->
            Windtrap.equal
              (Windtrap.option Windtrap.string)
              ~msg:"none"
              None
              (Soldev_ticket.premise_of "---\nid: X\n---\n\nBody\n"))
        ; Windtrap.test "blank probe is no probe" (fun () ->
            Windtrap.equal
              (Windtrap.option Windtrap.string)
              ~msg:"none"
              None
              (Soldev_ticket.premise_of "---\nid: X\npremise: \"  \"\n---\n\nBody\n"))
        ; Windtrap.test "exit 0 means stale" (fun () ->
            match
              Soldev_ticket.premise_verdict ~exit_code:0 ~missing_paths:[] ~output:""
            with
            | Soldev_ticket.Premise_stale -> ()
            | Soldev_ticket.Premise_holds -> Windtrap.fail "exit 0 must mean stale"
            | Soldev_ticket.Premise_unverified reason ->
              Windtrap.fail ("unexpected unverified: " ^ reason))
        ; Windtrap.test "exit 1 means the premise holds" (fun () ->
            match
              Soldev_ticket.premise_verdict ~exit_code:1 ~missing_paths:[] ~output:""
            with
            | Soldev_ticket.Premise_holds -> ()
            | _ -> Windtrap.fail "exit 1 means the premise still holds")
        ; Windtrap.test "an exit outside {0, 1} is unverified, naming the code" (fun () ->
            match
              Soldev_ticket.premise_verdict
                ~exit_code:2
                ~missing_paths:[]
                ~output:"sh: 1: syntax error: unexpected end of file"
            with
            | Soldev_ticket.Premise_unverified reason ->
              if not (Soldev_string.contains_substring ~needle:"2" reason)
              then Windtrap.fail ("the exit code is not named: " ^ reason)
            | _ ->
              Windtrap.fail "a probe that did not reach a conclusion is not a verdict")
        ; Windtrap.test "127 is unverified, not holds" (fun () ->
            match
              Soldev_ticket.premise_verdict ~exit_code:127 ~missing_paths:[] ~output:""
            with
            | Soldev_ticket.Premise_unverified _ -> ()
            | _ -> Windtrap.fail "a probe that cannot run must not read as holds")
        ; Windtrap.test "a quoted pattern is not a path" (fun () ->
            check_list_string
              "paths"
              [ "cli/lib/deploy/sol_cli_open.ml" ]
              (Soldev_ticket.named_paths "rg -q 'Traces' cli/lib/deploy/sol_cli_open.ml"))
        ; Windtrap.test "an existence-test operand is not a must-exist path" (fun () ->
            check_list_string
              "paths"
              [ "cli/actual.ml" ]
              (Soldev_ticket.named_paths
                 "test ! -f gone/missing.yml ; rg -q x cli/actual.ml"))
        ; Windtrap.test "a named path that does not exist is reported" (fun () ->
            check_list_string
              "missing"
              [ "gone/moved.ml" ]
              (Soldev_ticket.missing_named_paths
                 ~root:(Sys.getcwd ())
                 "rg -q x gone/moved.ml"))
        ; Windtrap.test
            "a negated probe over a missing path is unverified, not stale"
            (fun () ->
               match
                 Soldev_ticket.premise_verdict
                   ~exit_code:0
                   ~missing_paths:[ "gone/moved.ml" ]
                   ~output:""
               with
               | Soldev_ticket.Premise_unverified _ -> ()
               | Soldev_ticket.Premise_stale ->
                 Windtrap.fail "a read that never happened must not read as stale"
               | Soldev_ticket.Premise_holds -> Windtrap.fail "unexpected holds")
        ; Windtrap.test "a planted probe over a nonexistent path is unverified" (fun () ->
            let verdict, _ =
              Soldev_merge.evaluate_premise
                ~echo:false
                "grep -q sol definitely/not/here.ml"
            in
            match verdict with
            | Soldev_ticket.Premise_unverified reason ->
              if
                not
                  (Soldev_string.contains_substring
                     ~needle:"definitely/not/here.ml"
                     reason)
              then Windtrap.fail ("the missing path is not named: " ^ reason)
            | _ -> Windtrap.fail "a probe whose input does not exist must not decide")
        ; Windtrap.test "a planted shell syntax error is unverified" (fun () ->
            let verdict, _ = Soldev_merge.evaluate_premise ~echo:false "if" in
            match verdict with
            | Soldev_ticket.Premise_unverified reason ->
              if not (Soldev_string.contains_substring ~needle:"2" reason)
              then Windtrap.fail ("the exit code is not named: " ^ reason)
            | _ -> Windtrap.fail "a probe that never ran must not be a verdict")
        ]
    ]
;;
