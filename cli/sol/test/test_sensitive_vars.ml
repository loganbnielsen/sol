(* SEC-010: a secret the root declares must never reach the logged terraform argv,
   on any provider. The HARDEN-002 run-1 guard keyed on `Aws -> true | _ -> false`
   and so never ran on GCP, whose root creates Cloud SQL from the same db_password. *)

module S = Sol_cli_sensitive_vars

let contains haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

let strings = Alcotest.(list string)
let check = Alcotest.(check bool)

let fixture =
  {|variable "region" {
  type    = string
  default = "us-east-1"
}

variable "db_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
  default     = ""
}

variable "api_token" {
  type      = string
  sensitive = true
  validation {
    condition     = length(var.api_token) > 0
    error_message = "a brace in a string } must not end the block"
  }
}

variable "not_secret" {
  type      = string
  sensitive = false
}

variable "empty" {}

resource "null_resource" "x" {
  triggers = {
    sensitive = true
  }
}
|}
;;

let test_parser () =
  Alcotest.check
    strings
    "only sensitive = true variables, sorted"
    [ "api_token"; "db_password" ]
    (S.declared_in [ "variables.tf", fixture ])
;;

let test_parser_merges_files () =
  Alcotest.check
    strings
    "names from several files, without duplicates"
    [ "a"; "b" ]
    (S.declared_in
       [ "one.tf", "variable \"a\" {\n  sensitive = true\n}\n"
       ; "two.tf", "variable \"b\" {\n  sensitive = true\n}\n"
       ; "three.tf", "variable \"a\" {\n  sensitive = true\n}\n"
       ])
;;

(* Positive control against the real roots: both declare db_password sensitive, so
   the guard is derived from the roots rather than from a provider list. The test
   runs in _build/default/cli/sol/test; the roots are declared deps. *)
let real_root provider =
  match S.declared ~root:(Filename.concat "../../platform/infra" provider) with
  | Ok names -> names
  | Error message -> Alcotest.fail message
;;

let test_real_roots_declare_db_password () =
  check
    "AWS root declares db_password sensitive"
    true
    (List.mem "db_password" (real_root "aws"));
  check
    "GCP root declares db_password sensitive"
    true
    (List.mem "db_password" (real_root "gcp"))
;;

let refuses ~sensitive vars =
  match S.refuse_on_command_line ~sensitive ~vars with
  | Ok () -> false
  | Error _ -> true
;;

let test_refused_on_both_providers () =
  List.iter
    (fun provider ->
       check
         (provider ^ ": --var db_password is refused")
         true
         (refuses ~sensitive:(real_root provider) [ "region=r"; "db_password=hunter22" ]))
    [ "aws"; "gcp" ]
;;

let test_message_names_the_fix_not_the_value () =
  match
    S.refuse_on_command_line ~sensitive:[ "db_password" ] ~vars:[ "db_password=hunter22" ]
  with
  | Ok () -> Alcotest.fail "expected a refusal"
  | Error msg ->
    check "names TF_VAR_db_password" true (contains msg "TF_VAR_db_password");
    check "says why (the run log)" true (contains msg "run log");
    check "never echoes the value" false (contains msg "hunter22")
;;

let test_unaffected_without_the_declaration () =
  check
    "a root that declares no such variable is unaffected"
    false
    (refuses ~sensitive:[] [ "db_password=anything"; "region=r" ]);
  check
    "non-sensitive variables pass"
    false
    (refuses ~sensitive:[ "db_password" ] [ "region=r"; "create_rds=true" ]);
  check "no variables pass" false (refuses ~sensitive:[ "db_password" ] [])
;;

let test_unreadable_root_is_an_error () =
  check
    "an unreadable root fails closed"
    true
    (match S.declared ~root:"/nonexistent/sol-root" with
     | Error _ -> true
     | Ok _ -> false)
;;

let () =
  Alcotest.run
    "sensitive_vars"
    [ ( "declaration"
      , [ Alcotest.test_case "parser" `Quick test_parser
        ; Alcotest.test_case "several files" `Quick test_parser_merges_files
        ; Alcotest.test_case "real roots" `Quick test_real_roots_declare_db_password
        ; Alcotest.test_case "unreadable root" `Quick test_unreadable_root_is_an_error
        ] )
    ; ( "refusal"
      , [ Alcotest.test_case "both providers" `Quick test_refused_on_both_providers
        ; Alcotest.test_case "message" `Quick test_message_names_the_fix_not_the_value
        ; Alcotest.test_case "unaffected" `Quick test_unaffected_without_the_declaration
        ] )
    ]
;;
