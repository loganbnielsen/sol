(** Maturity-A compatibility contract (FEAT-088).

    The profile's supported framework languages are a small, declared set. A
    workload declares its language in [sol.yml]; nothing infers it from build
    metadata (DEC-022 §7). *)

type language =
  | Ocaml
  | Typescript

val all : language list
val to_string : language -> string

(** [of_string s] is case-insensitive; returns [Error msg] with the supported
    values for anything else. *)
val of_string : string -> (language, string) result

(** The languages a profile qualifies. DEC-026 §2 qualifies OCaml for
    [production-single-region/v1] and stages TypeScript behind explicit
    triggers. *)
val supported_by_profile : Sol_cli_profile.t -> language list

val is_supported_by_profile : Sol_cli_profile.t -> language -> bool
