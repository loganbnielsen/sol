let team_of_dir dir = Filename.basename dir
let generated_module ~dir = String.capitalize_ascii (team_of_dir dir) ^ "_contract"
let generated_basename ~dir = String.uncapitalize_ascii (generated_module ~dir)
let ocaml_path ~dir = Filename.concat dir (generated_basename ~dir ^ ".ml")

let typescript_path ~dir =
  Filename.concat
    (Filename.concat "app" (Filename.concat (team_of_dir dir) "contract"))
    (Filename.concat "src" (generated_basename ~dir ^ ".ts"))
;;

let generated_path ~dir ~(language : Sol_cli_toml.binding_language) =
  match language with
  | Ocaml -> ocaml_path ~dir
  | Typescript -> typescript_path ~dir
;;

let render_ocaml_event (event : Sol_cli_toml.event_decl) =
  let key_field =
    match event.key_field with
    | None -> "None"
    | Some field -> Printf.sprintf "Some %S" field
  in
  Printf.sprintf
    "module %s = struct\n\
    \  let topic_name = Kafka_service.topic_name_exn %S\n\
    \  let schema = %S\n\
    \  let partitions = %d\n\
    \  let key_field = %s\n\
     end\n"
    event.name
    event.topic
    event.schema
    event.partitions
    key_field
;;

let render_ocaml events =
  let body = String.concat "\n" (List.map render_ocaml_event events) in
  Printf.sprintf "[@@@ocamlformat \"disable\"]\n\n%s" body
;;

let render_typescript_event (event : Sol_cli_toml.event_decl) =
  let key_field =
    match event.key_field with
    | None -> "null"
    | Some field -> Yojson.Safe.to_string (`String field)
  in
  Printf.sprintf
    "export const %sSpec: EventContractSpec = {\n\
    \  name: %S,\n\
    \  schema: %s,\n\
    \  partitions: %d,\n\
    \  keyField: %s,\n\
     };\n"
    event.name
    event.topic
    (Yojson.Safe.to_string (`String event.schema))
    event.partitions
    key_field
;;

let typescript_prelude =
  "import type { TopicContract } from \"@sol-fab/kafka\";\n\n\
   export interface EventContractSpec {\n\
  \  readonly name: string;\n\
  \  readonly schema: string;\n\
  \  readonly partitions: number;\n\
  \  readonly keyField: string | null;\n\
   }\n\n\
   export function generatedContract<T>(spec: EventContractSpec): TopicContract<T> {\n\
  \  return {\n\
  \    name: spec.name,\n\
  \    schema: spec.schema,\n\
  \    partitions: spec.partitions,\n\
  \    key: (message) => {\n\
  \      if (spec.keyField === null) return undefined;\n\
  \      const value = (message as unknown as Record<string, unknown>)[spec.keyField];\n\
  \      return value === undefined || value === null ? undefined : String(value);\n\
  \    },\n\
  \  };\n\
   }\n\n"
;;

let render_typescript events =
  typescript_prelude ^ String.concat "\n" (List.map render_typescript_event events)
;;

type peer =
  { name : string
  ; service_name : string
  }

let peer_bindings_path ~dir ~(language : Sol_cli_compat.language) =
  match language with
  | Sol_cli_compat.Ocaml -> Filename.concat dir "lib/peer_bindings.ml"
  | Sol_cli_compat.Typescript -> Filename.concat dir "src/peer-bindings.ts"
;;

let peer_binding_name peer =
  let value = peer.name ^ "_" ^ peer.service_name in
  let value =
    String.map
      (function
        | ('a' .. 'z' | '0' .. '9' | '_') as c -> c
        | 'A' .. 'Z' as c -> Char.lowercase_ascii c
        | _ -> '_')
      value
  in
  if
    value = ""
    || not
         (match value.[0] with
          | 'a' .. 'z' | '_' -> true
          | _ -> false)
  then "peer_" ^ value
  else value
;;

let render_peer_bindings ~(language : Sol_cli_compat.language) peers =
  match language with
  | Sol_cli_compat.Ocaml ->
    let bindings =
      peers
      |> List.map (fun peer ->
        Printf.sprintf
          "let %s = Peer.For_codegen.declared ~unit_id:%S ~service_name:%S"
          (peer_binding_name peer)
          (peer.name ^ "/" ^ peer.service_name)
          peer.service_name)
      |> String.concat "\n"
    in
    Printf.sprintf "[@@@ocamlformat \"disable\"]\n\n%s\n" bindings
  | Sol_cli_compat.Typescript ->
    let bindings =
      peers
      |> List.map (fun peer ->
        Printf.sprintf
          "export const %s = declaredPeer(%s, %s);"
          (peer_binding_name peer)
          (Yojson.Safe.to_string (`String (peer.name ^ "/" ^ peer.service_name)))
          (Yojson.Safe.to_string (`String peer.service_name)))
      |> String.concat "\n"
    in
    Printf.sprintf "import { declaredPeer } from \"@sol-fab/svc\";\n\n%s\n" bindings
;;

let peer_of_reference ~dir reference =
  match String.split_on_char '/' reference with
  | [ name; service_name ] when name <> "" && service_name <> "" ->
    Ok { name; service_name }
  | _ -> Error (Printf.sprintf "%s has invalid service call %S" dir reference)
;;

let peer_bindings ~root =
  let open Result.Syntax in
  let* workspace = Sol_cli_workspace_model.load ~root in
  let services =
    workspace.workloads
    |> List.map (fun (workload : Sol_cli_workspace_model.workload) -> workload.service)
  in
  workspace.workloads
  |> List.filter_map (fun (workload : Sol_cli_workspace_model.workload) ->
    match workload.config with
    | Error error -> Some (Error (Sol_cli_toml.parse_error_to_string error))
    | Ok config when config.Sol_cli_toml.calls = [] -> None
    | Ok config ->
      (match workload.language with
       | None ->
         Some
           (Error
              (Printf.sprintf
                 "%s declares calls but has no language in sol.yml; typed peer bindings \
                  need the app language"
                 workload.service.dir))
       | Some language ->
         let peers =
           config.Sol_cli_toml.calls
           |> Sol_cli_result.map_list (peer_of_reference ~dir:workload.service.dir)
           |> fun peers_result ->
           Result.bind peers_result (fun peers ->
             peers
             |> Sol_cli_result.map_list (fun peer ->
               match
                 List.find_opt
                   (fun (service : Sol_cli_manifest.service) ->
                      service.domain = peer.name
                      && service.name = peer.service_name
                      && service.primitive = Sol_cli_manifest.Svc)
                   services
               with
               | Some _ -> Ok peer
               | None ->
                 Error
                   (Printf.sprintf
                      "%s calls missing service %S"
                      workload.service.dir
                      (peer.name ^ "/" ^ peer.service_name))))
         in
         Some
           (Result.bind peers (fun peers ->
              let peers = List.sort_uniq compare peers in
              let names = List.map peer_binding_name peers in
              if List.length names <> List.length (List.sort_uniq String.compare names)
              then
                Error
                  (Printf.sprintf
                     "%s has calls whose generated peer binding names collide"
                     workload.service.dir)
              else
                Ok
                  ( peer_bindings_path ~dir:workload.service.dir ~language
                  , render_peer_bindings ~language peers )))))
  |> Sol_cli_result.map_list Fun.id
;;

let render ~(language : Sol_cli_toml.binding_language) events =
  match language with
  | Ocaml -> render_ocaml events
  | Typescript -> render_typescript events
;;

let plan ~root =
  match Sol_cli_workspace_scan.discover_contracts ~root () with
  | Error error -> Error (Sol_cli_toml.parse_error_to_string error)
  | Ok contracts ->
    let event_files =
      List.map
        (fun (contract : Sol_cli_workspace_scan.contract) ->
           let path = generated_path ~dir:contract.dir ~language:contract.language in
           let content = render ~language:contract.language contract.events in
           path, content)
        contracts
    in
    Result.map (fun peer_files -> event_files @ peer_files) (peer_bindings ~root)
;;

type projection_issue =
  | Stale of string
  | Missing of string

let check_freshness ~root =
  match plan ~root with
  | Error error -> Error error
  | Ok files ->
    files
    |> List.filter_map (fun (path, content) ->
      let full = Filename.concat root path in
      match Sol_cli_fs.read_file_opt full with
      | Some existing when String.equal existing content -> None
      | Some _ -> Some (Stale path)
      | None -> Some (Missing path))
    |> Result.ok
;;

let projection_issue_to_string = function
  | Stale path -> Printf.sprintf "%s is stale; run `sol contract generate`" path
  | Missing path -> Printf.sprintf "%s is missing; run `sol contract generate`" path
;;

let generate ~root ~check =
  if check
  then (
    match check_freshness ~root with
    | Error error -> Error error
    | Ok [] -> Ok []
    | Ok issues -> Error (String.concat "\n" (List.map projection_issue_to_string issues)))
  else (
    match plan ~root with
    | Error error -> Error error
    | Ok files ->
      List.fold_left
        (fun acc (path, content) ->
           Result.bind acc (fun written ->
             let full = Filename.concat root path in
             Result.bind
               (Sol_cli_fs.mkdir_p (Filename.dirname full))
               (fun () ->
                  Result.bind (Sol_cli_fs.write_atomic full content) (fun () ->
                    Ok (path :: written)))))
        (Ok [])
        files
      |> Result.map List.rev)
;;
