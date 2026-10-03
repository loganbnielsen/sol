let url_encode s =
  let buf = Buffer.create (String.length s * 2) in
  s
  |> String.iter (fun c ->
    match c with
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' ->
      Buffer.add_char buf c
    | c -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)));
  Buffer.contents buf
;;

let loki_datasource_uid = "loki"
let tempo_datasource_uid = "tempo"

let explore_url ~base_url ~logql =
  let pane =
    `Assoc
      [ "datasource", `String loki_datasource_uid
      ; "queries", `List [ `Assoc [ "refId", `String "A"; "expr", `String logql ] ]
      ]
  in
  Printf.sprintf
    "%s/explore?orgId=1&left=%s"
    base_url
    (url_encode (Yojson.Safe.to_string pane))
;;

let traces_explore_url ~base_url ~traceql =
  let pane =
    `Assoc
      [ "datasource", `String tempo_datasource_uid
      ; ( "queries"
        , `List
            [ `Assoc
                [ "refId", `String "A"
                ; "queryType", `String "traceql"
                ; "query", `String traceql
                ]
            ] )
      ]
  in
  Printf.sprintf
    "%s/explore?orgId=1&left=%s"
    base_url
    (url_encode (Yojson.Safe.to_string pane))
;;

let grafana_explore_url ~base_url ~unit =
  explore_url ~base_url ~logql:(Sol_cli_log_selector.unit unit)
;;

let release_logql ~release_id = Printf.sprintf {|{release="%s"}|} release_id

type release_query =
  | Release_invalid of string
  | Release_unknown of
      { release_id : string
      ; target : string
      }
  | Release_logs of
      { release_id : string
      ; logql : string
      }

let release_query ~release ~target ~known ?unit () =
  match Sol_cli_release_id.of_string release with
  | Error msg -> Release_invalid msg
  | Ok id ->
    let release_id = Sol_cli_release_id.to_string id in
    if not (known id)
    then Release_unknown { release_id; target }
    else (
      let logql =
        match unit with
        | None -> release_logql ~release_id
        | Some unit -> Sol_cli_log_selector.unit_release unit ~release_id
      in
      Release_logs { release_id; logql })
;;

type kubectl_log_target =
  | Deployment of string
  | App_selector of string

let kubectl_logs_argv ~ctx ~ns ~target ~follow ~tail =
  let target_args =
    match target with
    | Deployment name -> [ "deployment/" ^ name ]
    | App_selector app -> [ "-l"; "app=" ^ app; "--all-containers=true" ]
  in
  [ "kubectl" ]
  @ Sol_cli_kube_destination.kubectl_context_args ctx
  @ [ "logs"; "-n"; ns ]
  @ target_args
  @ (if follow then [ "--follow" ] else [])
  @ [ "--tail=" ^ string_of_int tail ]
;;
