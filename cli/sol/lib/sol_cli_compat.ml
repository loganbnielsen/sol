(* FEAT-088: the maturity-A compatibility contract.

   A production workspace and target must be reproducible from a small,
   declared set of compatible Sol CLI, framework-language, Kubernetes,
   provider-module and platform-chart versions. The enforceable, language-neutral
   input is the application-facing language declaration in [sol.yml]: DEC-026 §2
   qualifies OCaml for the first profile and stages TypeScript behind explicit
   triggers. This module is the single source of truth for which languages exist
   and which the profile supports, so the [sol.yml] parser, the plan and the
   preflight cannot disagree. The pinned CLI/substrate/chart versions are
   recorded in docs/deployment/compatibility.md.

   Language is deliberately *declared*, never inferred from Dockerfiles, paths
   or package metadata: DEC-022 §7 keeps language out of deployment identity, so
   a guess here would be the same wrong abstraction the ticket rejects. *)

type language =
  | Ocaml
  | Typescript

let all = [ Ocaml; Typescript ]

let to_string = function
  | Ocaml -> "ocaml"
  | Typescript -> "typescript"
;;

let of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "ocaml" -> Ok Ocaml
  | "typescript" -> Ok Typescript
  | other ->
    Error
      (Printf.sprintf
         "unknown language %S (supported: %s)"
         other
         (all |> List.map to_string |> String.concat ", "))
;;

(* The profile's qualified language set (DEC-026 §2). TypeScript is staged, not
   rejected forever: the compatibility matrix records the qualification
   trigger. *)
let supported_by_profile (_ : Sol_cli_profile.t) = [ Ocaml ]

let is_supported_by_profile profile language =
  List.mem language (supported_by_profile profile)
;;
