(* SEC-010: a secret the root declares must never reach the logged terraform argv,
   on any provider. The HARDEN-002 run-1 guard keyed on `Aws -> true | _ -> false`
   and so never ran on GCP, whose root creates Cloud SQL from the same db_password.

   AUDIT-POST-006: the reader must not answer "no secrets" merely because a root is
   laid out differently from the ones it was written against, so the parser cases
   below cover the valid variants a root can have and the fail-closed path. *)

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
let declared names = Result.get_ok (S.declared_in names)

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

variable "commented_secret" {
  type      = string
  sensitive = true # the comment terraform fmt leaves alone
}

variable "spaced_secret" {
	type      = string
	sensitive	=	true
}

variable "inline_secret" { sensitive = true }

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

(* A valid root can carry those variants and terraform fmt leaves them alone, so the
   reader must not depend on the one layout the repository's own roots happen to
   use. The resource block's `sensitive = true` is deliberately not a variable
   declaration, and a false/short declaration is not a secret. *)
let test_parser () =
  Alcotest.check
    strings
    "every sensitive variable, and only those, sorted"
    [ "api_token"; "commented_secret"; "db_password"; "inline_secret"; "spaced_secret" ]
    (declared [ "variables.tf", fixture ])
;;

let test_parser_merges_files () =
  Alcotest.check
    strings
    "names from several files, without duplicates"
    [ "a"; "b" ]
    (declared
       [ "one.tf", "variable \"a\" {\n  sensitive = true\n}\n"
       ; "two.tf", "variable \"b\" {\n  sensitive = true\n}\n"
       ; "three.tf", "variable \"a\" {\n  sensitive = true\n}\n"
       ])
;;

(* Fail closed: a `sensitive` assignment the reader cannot evaluate must be reported
   rather than skipped, because skipping it is indistinguishable from "not a
   secret" and the secret would then reach the logged argv. *)
let test_unclassifiable_sensitive_is_an_error () =
  let cases =
    [ "an unresolved value", "variable \"a\" {\n  sensitive = var.is_secret\n}\n"
    ; ( "a one-line block with an unresolved value"
      , "variable \"a\" { sensitive = var.s }\n" )
    ]
  in
  List.iter
    (fun (what, contents) ->
       check
         (what ^ " fails closed")
         true
         (match S.declared_in [ "vars.tf", contents ] with
          | Error message -> contains message "vars.tf"
          | Ok _ -> false))
    cases
;;

(* ...and the error names the file and line, so the operator can fix it. *)
let test_unclassifiable_names_the_location () =
  match
    S.declared_in
      [ "vars.tf", "variable \"a\" {\n  type = string\n  sensitive = var.s\n}\n" ]
  with
  | Ok _ -> Alcotest.fail "expected the reader to fail closed"
  | Error message -> check "names file and line" true (contains message "vars.tf:3")
;;

(* Positive control against the real roots: both declare db_password sensitive, so
   the guard is derived from the roots rather than from a provider list. The test
   runs in _build/default/cli/sol/test; the roots are declared deps. *)
let real_root provider =
  match S.declared ~root:(Filename.concat "../../../platform/infra" provider) with
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
        ; Alcotest.test_case
            "unclassifiable sensitive"
            `Quick
            test_unclassifiable_sensitive_is_an_error
        ; Alcotest.test_case
            "unclassifiable names the location"
            `Quick
            test_unclassifiable_names_the_location
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
