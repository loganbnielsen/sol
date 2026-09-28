type test_outcome =
  | Dry_run of
      { url : string
      ; body : string
      }
  | Accepted of { url : string }

type test_error =
  | Invalid_target of Sol_cli_config.error
  | Invalid_delivery of string
  | Rejected of
      { exit_code : int
      ; stderr : string
      }
  | Unreachable of string

val test : string -> string -> bool -> (test_outcome, test_error) result
