(* FEAT-062: rendering a target as a target.

   The invariant worth asserting is the easy one to lose: the kube-context is a
   mechanism, not the target's identity (DEC-020), so it must not appear in the
   default rendering — only under --verbose. A "helper" that prints it "for
   clarity" would undo the point of FEAT-059. *)

open Sol_cli_target_report

let provider () =
  match Sol_cli_provider.of_string "aws" with
  | Some provider -> provider
  | None -> Alcotest.fail "aws should be a known provider"
;;

let target ?(kube_context = Some "prod-us-east-1") () : Sol_cli_config.target =
  { name = "prod/aws/us-east-1"
  ; env = "prod"
  ; provider = provider ()
  ; region = "us-east-1"
  ; registry = Some "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  ; base_domain = Some "acme.com"
  ; cluster_issuer = None
  ; cluster_name = Some "acme-prod"
  ; kube_context
  ; terraform_var_file = None
  ; observability_backend = None
  ; provider_fields = []
  }
;;

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

let value_of rows label = List.assoc_opt label rows

let all_text rows =
  rows |> List.concat_map (fun (label, value) -> [ label; value ]) |> String.concat " "
;;

let test_not_configured_points_at_the_field () =
  let message = Sol_cli_target_report.describe ~verbose:false Not_configured in
  assert (contains ~needle:"kube_context" message);
  assert (contains ~needle:"sol cloud init" message)
;;

let test_configured_is_not_checked_and_hides_the_context () =
  let message =
    Sol_cli_target_report.describe ~verbose:false (Configured "prod-us-east-1")
  in
  assert (contains ~needle:"not checked" message);
  assert (contains ~needle:"--check" message);
  (* Not checked must also mean not revealed: this is the masking rule. *)
  assert (not (contains ~needle:"prod-us-east-1" message))
;;

let test_verbose_shows_the_context () =
  let rows =
    Sol_cli_target_report.rows ~verbose:true (target ()) (Reachable "prod-us-east-1")
  in
  Alcotest.(check (option string))
    "raw context available when asked for"
    (Some "prod-us-east-1")
    (value_of rows "kube context")
;;

let test_default_summary_never_names_the_context () =
  let statuses =
    [ Not_configured
    ; Configured "prod-us-east-1"
    ; Reachable "prod-us-east-1"
    ; Unreachable ("prod-us-east-1", "connection refused")
    ]
  in
  List.iter
    (fun status ->
       let text =
         all_text (Sol_cli_target_report.rows ~verbose:false (target ()) status)
       in
       assert (not (contains ~needle:"prod-us-east-1" text)))
    statuses
;;

let test_rows_describe_the_target_not_a_cluster () =
  let rows = Sol_cli_target_report.rows ~verbose:false (target ()) (Configured "c") in
  Alcotest.(check (option string)) "region" (Some "us-east-1") (value_of rows "region");
  Alcotest.(check (option string)) "cluster" (Some "acme-prod") (value_of rows "cluster");
  Alcotest.(check bool)
    "provider present"
    true
    (Option.is_some (value_of rows "provider"));
  (* The target path and env are details, not the summary. *)
  Alcotest.(check (option string))
    "no target path by default"
    None
    (value_of rows "target");
  Alcotest.(check (option string)) "no env by default" None (value_of rows "env")
;;

let test_unreachable_carries_the_reason () =
  let message =
    Sol_cli_target_report.describe
      ~verbose:true
      (Unreachable ("prod-us-east-1", "connection refused"))
  in
  assert (contains ~needle:"connection refused" message);
  let quiet =
    Sol_cli_target_report.describe
      ~verbose:false
      (Unreachable ("prod-us-east-1", "connection refused"))
  in
  assert (contains ~needle:"connection refused" quiet);
  assert (not (contains ~needle:"prod-us-east-1" quiet))
;;

(* The JSON and text renderings share [rows], so this guards the claim rather
   than trusting it: a second rendering path is how two output formats drift. *)
let test_json_matches_rows () =
  let rows = Sol_cli_target_report.rows ~verbose:false (target ()) (Configured "c") in
  let json = Sol_cli_target_report.to_json ~verbose:false (target ()) (Configured "c") in
  let from_json =
    match json with
    | `Assoc fields ->
      List.map
        (fun (key, value) ->
           match value with
           | `String value -> key, value
           | _ -> Alcotest.fail "expected string values")
        fields
    | _ -> Alcotest.fail "expected an object"
  in
  Alcotest.(check (list (pair string string))) "same rows" rows from_json
;;

let () =
  Alcotest.run
    "target_report"
    [ ( "target_report"
      , [ Alcotest.test_case
            "not configured points at the field"
            `Quick
            test_not_configured_points_at_the_field
        ; Alcotest.test_case
            "configured is not checked and hides the context"
            `Quick
            test_configured_is_not_checked_and_hides_the_context
        ; Alcotest.test_case "the reason is filtered too" `Quick (fun () ->
            (* kubectl quotes the context back — `error: context "X" does not
               exist` — so filtering only the context field would satisfy the
               masking rule in appearance while the reason leaked the name. *)
            let reason = "error: context \"prod-us-east-1\" does not exist" in
            let quiet =
              Sol_cli_target_report.describe
                ~verbose:false
                (Unreachable ("prod-us-east-1", reason))
            in
            assert (contains ~needle:"does not exist" quiet);
            assert (not (contains ~needle:"prod-us-east-1" quiet));
            assert (contains ~needle:"<context>" quiet);
            let loud =
              Sol_cli_target_report.describe
                ~verbose:true
                (Unreachable ("prod-us-east-1", reason))
            in
            assert (contains ~needle:"prod-us-east-1" loud))
        ; Alcotest.test_case
            "verbose shows the context"
            `Quick
            test_verbose_shows_the_context
        ; Alcotest.test_case
            "default summary never names the context"
            `Quick
            test_default_summary_never_names_the_context
        ; Alcotest.test_case
            "rows describe the target"
            `Quick
            test_rows_describe_the_target_not_a_cluster
        ; Alcotest.test_case
            "unreachable carries the reason"
            `Quick
            test_unreachable_carries_the_reason
        ; Alcotest.test_case "json matches rows" `Quick test_json_matches_rows
        ] )
    ]
;;
