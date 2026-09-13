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

(* FEAT-069: a release-scoped query. The release id is workspace-unique by
   construction (the workspace and environment are part of the hashed content),
   so the exact [release] label is the whole selector when no unit narrows it. *)
let release_logql ~release_id = Printf.sprintf {|{release="%s"}|} release_id

let unit_release_logql ~ns ~k8s_name ~release_id =
  Printf.sprintf {|{namespace="%s",app="%s",release="%s"}|} ns k8s_name release_id
;;

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

(** [release_query ~release ~target ~known ?scope ()] classifies a [--release]
    argument. The order is the contract: the id is validated first, so a
    malformed value returns [Release_invalid] *without* [known] ever being
    called — the release store must not be consulted for input that is not an
    id. [Release_unknown] and [Release_logs] stay distinct because "no such
    release" is an error while "a known release with no logs" is an empty
    success, and collapsing them would misreport a real release.

    [~scope] is the already-validated [(namespace, k8s_name)] of a unit, when
    one was given; it narrows the selector to that workload. *)
let release_query ~release ~target ~known ?scope () =
  match Sol_cli_release_id.of_string release with
  | Error msg -> Release_invalid msg
  | Ok id ->
    let release_id = Sol_cli_release_id.to_string id in
    if not (known id)
    then Release_unknown { release_id; target }
    else (
      let logql =
        match scope with
        | None -> release_logql ~release_id
        | Some (ns, k8s_name) -> unit_release_logql ~ns ~k8s_name ~release_id
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
