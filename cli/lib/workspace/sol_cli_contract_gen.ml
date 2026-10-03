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

let render ~(language : Sol_cli_toml.binding_language) events =
  match language with
  | Ocaml -> render_ocaml events
  | Typescript -> render_typescript events
;;

let plan ~root =
  match Sol_cli_workspace_scan.discover_contracts ~root () with
  | Error error -> Error (Sol_cli_toml.parse_error_to_string error)
  | Ok contracts ->
    Ok
      (List.map
         (fun (contract : Sol_cli_workspace_scan.contract) ->
            let path = generated_path ~dir:contract.dir ~language:contract.language in
            let content = render ~language:contract.language contract.events in
            path, content)
         contracts)
;;

let generate ~root ~check =
  match plan ~root with
  | Error error -> Error error
  | Ok files ->
    if check
    then (
      let problems =
        List.filter_map
          (fun (path, content) ->
             let full = Filename.concat root path in
             match Sol_cli_fs.read_file_opt full with
             | Some existing when String.equal existing content -> None
             | Some _ ->
               Some (Printf.sprintf "%s is stale; run `sol contract generate`" path)
             | None ->
               Some (Printf.sprintf "%s is missing; run `sol contract generate`" path))
          files
      in
      if problems = [] then Ok [] else Error (String.concat "\n" problems))
    else
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
      |> Result.map List.rev
;;
