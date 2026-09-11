(* Helpers for the 'sol logs' command.
   Pure utility functions are kept here (no I/O) so they can be unit-tested
   without pulling in Cmdliner or Sys. *)

(* Percent-encode characters that are not safe inside a LogQL expression
   embedded as a query-parameter value.  We only encode the small set of
   characters that actually appear in a LogQL label-selector literal so the
   output stays readable. *)
let url_encode_logql s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter
    (fun c ->
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
          | c -> String.make 1 c))
    s;
  Buffer.contents buf
;;

(* Build a Grafana Explore URL for the given raw LogQL query. *)
let explore_url ~base_url ~logql =
  let encoded = url_encode_logql logql in
  Printf.sprintf
    "%s/explore?orgId=1&left=%%7B%%22datasource%%22:%%22loki%%22,%%22queries%%22:%%5B%%7B%%22expr%%22:%%22%s%%22%%7D%%5D%%7D"
    base_url
    encoded
;;

(* Build a Grafana Explore URL scoped to one service.
   base_url: e.g. "http://localhost:3000"
   ns:       Kubernetes namespace
   k8s_name: service k8s name (hyphens, lowercase)
   Returns a URL the operator can paste directly into a browser. *)
let grafana_explore_url ~base_url ~ns ~k8s_name =
  explore_url ~base_url ~logql:(Printf.sprintf {|{namespace="%s",app="%s"}|} ns k8s_name)
;;

type kubectl_log_target =
  | Deployment of string
  | App_selector of string

let kubectl_logs_argv ~ns ~target ~follow ~tail =
  let target_args =
    match target with
    | Deployment name -> [ "deployment/" ^ name ]
    | App_selector app -> [ "-l"; "app=" ^ app; "--all-containers=true" ]
  in
  [ "kubectl"; "logs"; "-n"; ns ]
  @ target_args
  @ (if follow then [ "--follow" ] else [])
  @ [ "--tail=" ^ string_of_int tail ]
;;
