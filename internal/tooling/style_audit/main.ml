open Parsetree
open Asttypes

type parameter =
  { label : string option
  ; optional : bool
  ; defaulted : bool
  ; noop : bool
  }

type finding =
  { file : string
  ; line : int
  ; column : int
  ; name : string
  ; rule : string
  ; message : string
  ; parameters : int
  ; optional : int
  ; defaulted : int
  ; noop_defaults : int
  ; family : string list
  }

let anonymous = { label = None; optional = false; defaulted = false; noop = false }

let rec noop expression =
  match expression.pexp_desc with
  | Pexp_ident
      { txt = Lident "ignore" | Ldot ({ txt = Lident "Stdlib"; _ }, { txt = "ignore"; _ })
      ; _
      } -> true
  | Pexp_function (_, _, Pfunction_body body) ->
    (match body.pexp_desc with
     | Pexp_construct ({ txt = Lident "()"; _ }, None) -> true
     | _ -> false)
  | Pexp_constraint (expression, _) -> noop expression
  | _ -> false
;;

let parameter label default =
  { label =
      (match label with
       | Nolabel -> None
       | Labelled name | Optional name -> Some name)
  ; optional =
      (match label with
       | Optional _ -> true
       | _ -> false)
  ; defaulted = Option.is_some default
  ; noop = Option.fold ~none:false ~some:noop default
  }
;;

let rec parameters expression =
  match expression.pexp_desc with
  | Pexp_function (params, _, body) ->
    let own =
      params
      |> List.filter_map (fun param ->
        match param.pparam_desc with
        | Pparam_val (label, default, _) -> Some (parameter label default)
        | Pparam_newtype _ -> None)
    in
    own
    @
      (match body with
      | Pfunction_body body -> parameters body
      | Pfunction_cases _ -> [ anonymous ])
  | Pexp_constraint (expression, _) | Pexp_coerce (expression, _, _) ->
    parameters expression
  | _ -> []
;;

let rec signature_parameters typ =
  match typ.ptyp_desc with
  | Ptyp_arrow (label, _, rest) -> parameter label None :: signature_parameters rest
  | Ptyp_poly (_, typ) -> signature_parameters typ
  | _ -> []
;;

let rec binding_name pattern =
  match pattern.ppat_desc with
  | Ppat_var name -> Some name
  | Ppat_constraint (pattern, _) -> binding_name pattern
  | _ -> None
;;

let prefix label =
  match String.index_opt label '_' with
  | Some index when index > 0 && index < String.length label - 1 ->
    Some (String.sub label 0 (index + 1))
  | _ -> None
;;

let findings ~file ~name ~location params =
  let count (predicate : parameter -> bool) =
    List.fold_left (fun n p -> if predicate p then n + 1 else n) 0 params
  in
  let total = List.length params in
  let optional = count (fun p -> p.optional) in
  let defaulted = count (fun p -> p.defaulted) in
  let noop_defaults = count (fun p -> p.noop) in
  let finding ~rule ~message ~family =
    let position = location.Location.loc_start in
    { file
    ; line = position.pos_lnum
    ; column = position.pos_cnum - position.pos_bol + 1
    ; name
    ; rule
    ; message
    ; parameters = total
    ; optional
    ; defaulted
    ; noop_defaults
    ; family
    }
  in
  let sprawl =
    if total >= 12 || optional >= 4
    then
      [ finding
          ~rule:"parameter-sprawl"
          ~message:
            (Printf.sprintf
               "%d parameters (%d optional, %d defaulted, %d no-op defaults); review \
                whether inputs form distinct concepts"
               total
               optional
               defaulted
               noop_defaults)
          ~family:[]
      ]
    else []
  in
  let labels = List.filter_map (fun p -> p.label) params in
  let families =
    labels
    |> List.filter_map prefix
    |> List.sort_uniq String.compare
    |> List.filter_map (fun prefix ->
      let members = List.filter (String.starts_with ~prefix) labels in
      let threshold = if prefix = "on_" then 3 else 4 in
      if List.length members < threshold
      then None
      else
        Some
          (finding
             ~rule:"parameter-family"
             ~message:
               (Printf.sprintf
                  "%d %s parameters (%s); review whether they form a cohesive \
                   hooks/config type"
                  (List.length members)
                  prefix
                  (String.concat ", " members))
             ~family:members))
  in
  sprawl @ families
;;

let inspect file =
  In_channel.with_open_bin file (fun channel ->
    let lexbuf = Lexing.from_channel channel in
    Location.init lexbuf file;
    let found = ref [] in
    let add name location params =
      found := List.rev_append (findings ~file ~name ~location params) !found
    in
    let default = Ast_iterator.default_iterator in
    let iterator =
      { default with
        value_binding =
          (fun self binding ->
            binding_name binding.pvb_pat
            |> Option.iter (fun name ->
              add name.txt name.loc (parameters binding.pvb_expr));
            default.value_binding self binding)
      ; value_description =
          (fun self description ->
            add
              description.pval_name.txt
              description.pval_name.loc
              (signature_parameters description.pval_type);
            default.value_description self description)
      }
    in
    if Filename.check_suffix file ".mli"
    then iterator.signature iterator (Parse.interface lexbuf)
    else iterator.structure iterator (Parse.implementation lexbuf);
    List.rev !found)
;;

let excluded = [ "_build"; "_opam"; ".git"; "node_modules"; "vendor" ]

let rec files path =
  match (Unix.lstat path).st_kind with
  | Unix.S_REG when Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli"
    -> [ path ]
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter (fun name ->
      (not (List.mem name excluded)) && not (String.starts_with ~prefix:"." name))
    |> List.concat_map (fun name -> files (Filename.concat path name))
  | _ -> []
;;

let json finding =
  `Assoc
    [ "file", `String finding.file
    ; "line", `Int finding.line
    ; "column", `Int finding.column
    ; "function", `String finding.name
    ; "rule", `String finding.rule
    ; "message", `String finding.message
    ; "parameters", `Int finding.parameters
    ; "optional", `Int finding.optional
    ; "defaulted", `Int finding.defaulted
    ; "noop_defaults", `Int finding.noop_defaults
    ; "family", `List (List.map (fun name -> `String name) finding.family)
    ]
;;

let () =
  let json_output = ref false in
  let paths = ref [] in
  Arg.parse
    [ "--json", Arg.Set json_output, "Emit a JSON array of advisory findings" ]
    (fun path -> paths := path :: !paths)
    "style_audit [--json] [FILE_OR_DIRECTORY ...]";
  let paths = if !paths = [] then [ "." ] else List.rev !paths in
  let failed = ref false in
  let report_error error =
    failed := true;
    match error with
    | Unix.Unix_error _ | Sys_error _ -> Format.eprintf "%s@." (Printexc.to_string error)
    | _ -> Location.report_exception Format.err_formatter error
  in
  let scanned =
    paths
    |> List.concat_map (fun path ->
      try files path with
      | error ->
        report_error error;
        [])
    |> List.sort_uniq String.compare
  in
  let findings =
    scanned
    |> List.concat_map (fun file ->
      try inspect file with
      | error ->
        report_error error;
        [])
  in
  if !json_output
  then Yojson.Safe.pretty_to_channel stdout (`List (List.map json findings))
  else
    findings
    |> List.iter (fun finding ->
      Printf.printf
        "%s:%d:%d: [%s] %s: %s\n"
        finding.file
        finding.line
        finding.column
        finding.rule
        finding.name
        finding.message);
  if !json_output then print_newline ();
  if !failed then exit 1
;;
