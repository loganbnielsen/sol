(* REFAC-096 (plan stage S8): the cluster a cloud root produced, as the lifecycle
   sees it.

   The lifecycle used to carry `cloud_outputs`, a variant with one constructor per
   provider, and read provider-shaped facts through whichever branch it had -- 17 dispatch sites
   in the command alone. What apply and destroy actually need from a cluster is
   small: its name, the platform variables its root wired, a way to reach it with
   the provisioner's credentials, whether it is ready, and how Sol's temporary
   bootstrap authority on it is observed. That is this record. Each provider
   builds one from its own outputs (Sol_cli_aws_cluster, Sol_cli_gcp_cluster);
   the output records and their parsing stay private to those modules, and
   nothing generic reads a field only one provider fills in. *)

type platform_vars_context =
  | Install
  | Destruction

(* The provider's share of the platform definition's variables: [fixed] follows
   the shared ones, and [optional] is applied, in order, after the target's own
   optional settings. The split keeps the argument order exactly what it was when
   each provider's branch assembled it. *)
type platform_vars =
  { fixed : string list
  ; optional : (string * string option) list
  }

(* DEC-040's bootstrap window, where Sol grants and revokes it itself. [observe]
   runs while the window is open and remembers what it saw; [deescalated] runs
   after the removal and compares against it, answering [Error verdict] when the
   removal cannot be shown effective. *)
type window =
  { gate : unit -> (unit, string) result
  ; observe : unit -> (unit, string) result
  ; deescalated : unit -> (unit, string) result
  ; principal : string
  }

type bootstrap_window =
  | Verified of window
  | No_role_declared
  (** The provider's elevation is scoped to a role the target does not declare,
      so nothing was elevated -- said out loud rather than skipped. *)
  | Closed_by_platform_root
  (** The window lives in the platform root and is closed by applying it; there is
      no Sol-side revocation to verify. *)

type t =
  { name : string
  ; check_identity : cluster_access_role_arn:string option -> (unit, string) result
  ; platform_vars :
      platform_vars_context
      -> cluster_issuer:string option
      -> region:string
      -> (platform_vars, string) result
  ; with_access :
      'a. (env:(string * string) list -> ('a, string) result) -> ('a, string) result
  ; ready : unit -> bool
  ; bootstrap_window : bootstrap_window
  }

(* HARDEN-002 run 4, finding 12. The base-platform providers are hashicorp/
   kubernetes and hashicorp/helm, configured implicitly (platform/infra/base
   declares no `provider` block). hashicorp/kubernetes 2.38.0 resolves the
   kubeconfig from `KUBE_CONFIG_PATH`/`KUBE_CONFIG_PATHS` and falls back to
   `~/.kube/config` -- it does NOT consult `KUBECONFIG`, which is the only name
   Sol used to export. So the platform phase silently used the operator's
   ambient kubeconfig (or none) and could not reach the provisioned cluster
   (`dial tcp 127.0.0.1:80`). Export every name the providers read, all pointing
   at the same ephemeral provisioner kubeconfig, so the phase is deterministic
   and never ambient. *)
let provisioner_kube_env path =
  [ "KUBECONFIG", path; "KUBE_CONFIG_PATH", path; "KUBE_CONFIG_PATHS", path ]
;;

(* Shared by both providers' parsers, because the one thing that has actually
   bitten the output contract is provider-independent. (HARDEN-002 run 3, finding
   10: Terraform *omits* an output whose value is `null` (v1.9.8) rather than
   emitting it as present-with-null. `member` yields `Null` for a missing key and
   `member "value"` on `Null` raises, so an absent *optional* output — every
   `loki_*`/`thanos_*` bucket unless durable observability is enabled — must
   resolve to `Null` and behave like a null value, while an absent *required*
   output still fails closed with a named error instead of crashing the
   lifecycle.) *)
let outputs_reader ~provider text =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string text in
  let value name =
    match json |> member name with
    | `Null -> `Null
    | output -> output |> member "value"
  in
  let string name =
    match value name with
    | `String s when String.trim s <> "" -> Ok s
    | _ ->
      Error
        (Printf.sprintf "%s Terraform output %S is missing or not a string" provider name)
  in
  let optional_string name =
    match value name with
    | `Null -> Ok None
    | `String s -> Ok (if String.trim s = "" then None else Some s)
    | _ ->
      Error
        (Printf.sprintf "%s Terraform output %S is not a string or null" provider name)
  in
  value, string, optional_string
;;

let process_ok ?(env = []) argv =
  match Sol_cli_process.run (Sol_cli_process.cmd ~env argv) with
  | Ok result -> result.exit_code = 0
  | Error _ -> false
;;

let process_output ?(env = []) argv =
  match Sol_cli_process.run (Sol_cli_process.cmd ~env argv) with
  | Ok result when result.exit_code = 0 -> Some result.stdout
  | _ -> None
;;
