type error = [ `Config of string ]

let error_to_string (`Config msg) = "sol-svc peer: config error: " ^ msg

let env_var source_name =
  source_name
  |> String.map (function
    | 'a' .. 'z' as c -> Char.uppercase_ascii c
    | ('A' .. 'Z' | '0' .. '9') as c -> c
    | _ -> '_')
  |> fun s -> s ^ "_URL"
;;

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None
;;

let url peer =
  let name = env_var peer in
  match env_nonempty name with
  | Some value ->
    let uri = Uri.of_string value in
    (match Uri.scheme uri, Uri.host uri with
     | Some ("http" | "https"), Some _ -> Ok uri
     | _ -> Error (`Config (name ^ " must be an absolute http(s) URL")))
  | None -> Error (`Config (name ^ " is not set"))
;;

let header_name_equal a b = String.lowercase_ascii a = String.lowercase_ascii b

let put_header name value headers =
  (name, value) :: List.filter (fun (k, _) -> not (header_name_equal k name)) headers
;;

let api_key ~env =
  match env_nonempty "SOL_API_KEY_FILE", env_nonempty "SOL_API_KEY" with
  | Some path, _ ->
    (try
       let key = String.trim (Eio.Path.load Eio.Path.(env#fs / path)) in
       if key = "" then Error (`Config ("API key file is empty: " ^ path)) else Ok key
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
     | exn ->
       Error
         (`Config
             ("could not read SOL_API_KEY_FILE " ^ path ^ ": " ^ Printexc.to_string exn)))
  | None, Some key -> Ok key
  | None, None -> Error (`Config "SOL_API_KEY/SOL_API_KEY_FILE is not set")
;;

let headers ~env ?trace_ctx ?(headers = []) ~peer:_ () =
  match api_key ~env with
  | Error _ as err -> err
  | Ok key ->
    let headers = put_header "x-api-key" key headers in
    Ok
      (match trace_ctx with
       | None -> headers
       | Some ctx -> Obs_trace.inject_to_headers ctx headers)
;;
