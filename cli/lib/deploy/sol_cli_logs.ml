let url_encode_logql s =
  let buf = Buffer.create (String.length s * 2) in
  s
  |> String.iter (fun c ->
    Buffer.add_string
      buf
      (match c with
       | '{' -> "%7B"
       | '}' -> "%7D"
       | '"' -> "%22"
       | ',' -> "%2C"
       | '=' -> "%3D"
       | ' ' -> "%20"
       | '%' -> "%25"
       | '+' -> "%2B"
       | '&' -> "%26"
       | '?' -> "%3F"
       | '#' -> "%23"
       | c -> String.make 1 c));
  Buffer.contents buf
;;

let explore_url ~base_url ~logql =
  let encoded = url_encode_logql logql in
  Printf.sprintf
    "%s/explore?orgId=1&left=%%7B%%22datasource%%22:%%22loki%%22,%%22queries%%22:%%5B%%7B%%22expr%%22:%%22%s%%22%%7D%%5D%%7D"
    base_url
    encoded
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
