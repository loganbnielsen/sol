type t = Yaml.yaml

(* libyaml takes C strings, so a NUL would silently end the value there. The
   boundaries that decode user text (sol.toml, migration files) refuse one, so
   reaching this is a caller's bug, and it must not become a truncated value. *)
let scalar style value =
  if String.contains value '\000'
  then invalid_arg "Sol_cli_yaml: a NUL character cannot be written to YAML";
  `Scalar
    { Yaml.anchor = None
    ; tag = None
    ; value
    ; plain_implicit = true
    ; quoted_implicit = true
    ; style
    }
;;

(* YAML 1.1's implicit types, as Kubernetes' decoder (go-yaml v2 underneath
   sigs.k8s.io/yaml) resolves them: a plain scalar spelled like one of these is
   not a string. *)
let resolves_to_non_string s =
  let words =
    [ "y"
    ; "yes"
    ; "n"
    ; "no"
    ; "true"
    ; "false"
    ; "on"
    ; "off"
    ; "null"
    ; "~"
    ; ".inf"
    ; "-.inf"
    ; "+.inf"
    ; ".nan"
    ]
  in
  let numeric_char = function
    | '0' .. '9' | '.' | '_' | ':' | '+' | '-' | 'e' | 'E' | 'x' | 'X' | 'o' -> true
    | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false
  in
  let starts_numeric =
    match s.[0] with
    | '0' .. '9' -> true
    | '+' | '-' | '.' -> String.length s > 1 && s.[1] >= '0' && s.[1] <= '9'
    | _ -> false
  in
  List.mem (String.lowercase_ascii s) words
  || (starts_numeric && String.for_all numeric_char s)
;;

let plain_safe s =
  let first_ok = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '.' | '/' -> true
    | _ -> false
  in
  let rest_ok = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '.' | '/' | '-' | ':' | '@' | '+' ->
      true
    | _ -> false
  in
  s <> ""
  && first_ok s.[0]
  && String.for_all rest_ok s
  && s.[String.length s - 1] <> ':'
  && not (resolves_to_non_string s)
;;

let quoted s = scalar `Double_quoted s
let string s = if plain_safe s then scalar `Plain s else quoted s
let literal s = scalar `Literal s
let int n = scalar `Plain (string_of_int n)
let bool b = scalar `Plain (string_of_bool b)

let map members =
  `O
    { Yaml.m_anchor = None
    ; m_tag = None
    ; m_implicit = true
    ; m_members = List.map (fun (key, value) -> string key, value) members
    }
;;

let list members =
  `A { Yaml.s_anchor = None; s_tag = None; s_implicit = true; s_members = members }
;;

type document =
  { comments : string list
  ; body : t
  }

let document ?(comments = []) body = { comments; body }

(* ocaml-yaml's emitter writes into a fixed buffer and reports overflow as an
   error; the only error it can report for a value built above. Grow and retry. *)
let rec emit ~len body =
  match Yaml.yaml_to_string ~len body with
  | Ok text -> text
  | Error _ when len < 1 lsl 26 -> emit ~len:(len * 4) body
  | Error (`Msg message) -> invalid_arg ("Sol_cli_yaml.render: " ^ message)
;;

let to_string body = emit ~len:(1 lsl 18) body

let render_document { comments; body } =
  let comments = comments |> List.map (fun line -> "# " ^ line ^ "\n") in
  String.concat "" (("---\n" :: comments) @ [ to_string body ])
;;

let render documents = documents |> List.map render_document |> String.concat ""
