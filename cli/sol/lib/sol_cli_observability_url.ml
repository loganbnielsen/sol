(* Backend-aware observability UI URL resolution (OBS-012). One resolver,
   used by sol logs/sol open/sol status's "Open" hints alike, instead of
   each command inventing its own flag and default. *)

type backend = Local | Self_hosted_durable | External

let backend_of_string = function
  | "local" -> Some Local
  | "self_hosted_durable" -> Some Self_hosted_durable
  | "external" -> Some External
  | _ -> None

let backend_to_string = function
  | Local -> "local"
  | Self_hosted_durable -> "self_hosted_durable"
  | External -> "external"

type resolution =
  | Url of string
  | No_url of string
  (** [No_url reason] — there is nothing safe to link to; [reason] is a
      short, printable explanation for the caller to show the user instead
      of a broken/guessed link. *)

(* Extension point: a future Sol-hosted UI is a fourth resolvable target.
   It would add a case here (e.g. [Sol_hosted of { release_url : string }])
   and a matching branch below -- callers already handle [No_url] instead
   of assuming every backend resolves, so adding a case is additive. *)

(** [resolve ~backend ?base_domain ?override ()] resolves the base
    observability UI URL for [backend].
    - [override], when given, always wins (e.g. sol logs's
      [--grafana-base-url] flag) -- the resolver is a default, not a lock.
    - [Local] defaults to ["http://localhost:3000"] (the standard dev
      port-forward address).
    - [Self_hosted_durable] resolves to ["https://grafana.<base_domain>"],
      matching cli/platform/infra/base's own Grafana Ingress
      (kubernetes_ingress_v1.grafana) -- requires [base_domain].
    - [External] never guesses: Sol doesn't know the shape of an
      arbitrary vendor's dashboard URL (Grafana Cloud, Datadog, ...). *)
let resolve ~backend ?base_domain ?override () =
  match override with
  | Some url -> Url url
  | None ->
    match backend with
    | Local -> Url "http://localhost:3000"
    | Self_hosted_durable ->
      (match base_domain with
       | Some d when String.trim d <> "" -> Url (Printf.sprintf "https://grafana.%s" d)
       | _ ->
         No_url
           "self_hosted_durable requires --base-domain to resolve the Grafana URL")
    | External ->
      No_url
        "no generated URL for the \"external\" backend -- check your configured observability provider directly"

(* OBS-015: sol status/logs/open used to default straight to Local/no
   base_domain, with no path to the target's actual configuration --
   "backend-aware" in name only. Reuse sol plan/sol cloud tf's existing
   target-resolution path (Sol_cli_config.load_for_target) instead of
   inventing a second, disconnected notion of "target". *)

(** [effective_backend_and_base_domain ~explicit_backend ~explicit_base_domain
    ~target ()] layers explicit CLI flags over [target]'s config over the
    hardcoded [Local] default:
    - an explicit flag always wins when given;
    - otherwise, when [target] (an [<env>/<provider>/<region>] path) is
      given, its [sol.yml] config supplies the backend/base_domain;
    - otherwise falls back to [Local]/[None], matching today's behavior.
    [Error _] covers: [target] fails to load, resolves to no target, or
    sets an [observability_backend] value that isn't one of
    ["local"|"self_hosted_durable"|"external"]. *)
let effective_backend_and_base_domain
    ~explicit_backend ~explicit_base_domain ~target () =
  match target with
  | None ->
    Ok (Option.value explicit_backend ~default:Local, explicit_base_domain)
  | Some target_path ->
    match Sol_cli_config.load_for_target ~target:target_path with
    | Error e -> Error (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      match Sol_cli_config.target cfg with
      | None -> Error (Printf.sprintf "target %S not found" target_path)
      | Some t ->
        let target_backend =
          match t.Sol_cli_config.observability_backend with
          | None -> Ok None
          | Some s ->
            (match backend_of_string s with
             | Some b -> Ok (Some b)
             | None ->
               Error (Printf.sprintf
                        "target %s has invalid observability_backend %S \
                         (expected: local, self_hosted_durable, external)"
                        target_path s))
        in
        (match target_backend with
         | Error e -> Error e
         | Ok target_backend ->
           let backend = match explicit_backend with
             | Some b -> b
             | None -> Option.value target_backend ~default:Local
           in
           let base_domain = match explicit_base_domain with
             | Some _ -> explicit_base_domain
             | None -> t.Sol_cli_config.base_domain
           in
           Ok (backend, base_domain))
