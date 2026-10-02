module S = Sol_cli_sensitive_vars

let contains haystack needle = Sol_cli_string.contains ~needle haystack
let strings = Windtrap.(list string)
let check msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
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

let test_parser () =
  Windtrap.equal
    strings
    ~msg:"every sensitive variable, and only those, sorted"
    [ "api_token"; "commented_secret"; "db_password"; "inline_secret"; "spaced_secret" ]
    (declared [ "variables.tf", fixture ])
;;

let test_parser_merges_files () =
  Windtrap.equal
    strings
    ~msg:"names from several files, without duplicates"
    [ "a"; "b" ]
    (declared
       [ "one.tf", "variable \"a\" {\n  sensitive = true\n}\n"
       ; "two.tf", "variable \"b\" {\n  sensitive = true\n}\n"
       ; "three.tf", "variable \"a\" {\n  sensitive = true\n}\n"
       ])
;;

let test_unclassifiable_sensitive_is_an_error () =
  let cases =
    [ "an unresolved value", "variable \"a\" {\n  sensitive = var.is_secret\n}\n"
    ; ( "a one-line block with an unresolved value"
      , "variable \"a\" { sensitive = var.s }\n" )
    ]
  in
  cases
  |> List.iter (fun (what, contents) ->
    check
      (what ^ " fails closed")
      true
      (match S.declared_in [ "vars.tf", contents ] with
       | Error message -> contains message "vars.tf"
       | Ok _ -> false))
;;

let test_unclassifiable_names_the_location () =
  match
    S.declared_in
      [ "vars.tf", "variable \"a\" {\n  type = string\n  sensitive = var.s\n}\n" ]
  with
  | Ok _ -> Windtrap.fail "expected the reader to fail closed"
  | Error message -> check "names file and line" true (contains message "vars.tf:3")
;;

let real_root provider =
  match
    S.declared ~root:(Printf.sprintf "../../../platform/cloud/%s/cluster" provider)
  with
  | Ok names -> names
  | Error message -> Windtrap.fail message
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

let providers_with_roots () =
  Sol_cli_provider.all
  |> List.map Sol_cli_provider.to_string
  |> List.filter (fun p ->
    Sys.file_exists (Printf.sprintf "../../../platform/cloud/%s/cluster" p))
;;

let test_refused_on_every_provider () =
  let providers = providers_with_roots () in
  check "at least one provider has a cluster root" true (providers <> []);
  providers
  |> List.iter (fun provider ->
    check
      (provider ^ ": --var db_password is refused")
      true
      (refuses ~sensitive:(real_root provider) [ "region=r"; "db_password=hunter22" ]))
;;

let test_message_names_the_fix_not_the_value () =
  match
    S.refuse_on_command_line ~sensitive:[ "db_password" ] ~vars:[ "db_password=hunter22" ]
  with
  | Ok () -> Windtrap.fail "expected a refusal"
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

let%test "declaration: parser" = test_parser ()
let%test "declaration: several files" = test_parser_merges_files ()

let%test "declaration: unclassifiable sensitive" =
  test_unclassifiable_sensitive_is_an_error ()
;;

let%test "declaration: unclassifiable names the location" =
  test_unclassifiable_names_the_location ()
;;

let%test "declaration: real roots" = test_real_roots_declare_db_password ()
let%test "declaration: unreadable root" = test_unreadable_root_is_an_error ()
let%test "refusal: every provider with a root" = test_refused_on_every_provider ()
let%test "refusal: message" = test_message_names_the_fix_not_the_value ()
let%test "refusal: unaffected" = test_unaffected_without_the_declaration ()
