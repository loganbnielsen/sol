(* Backend-aware observability UI URL resolution (OBS-012). One resolver,
   used by sol logs/sol open/sol status's "Open" hints alike, instead of
   each command inventing its own flag and default. *)

type backend = Local | Self_hosted_durable | External

val backend_of_string : string -> backend option
val backend_to_string : backend -> string

type resolution =
  | Url of string
  | No_url of string
  (** [No_url reason] — there is nothing safe to link to; [reason] is a
      short, printable explanation for the caller to show the user instead
      of a broken/guessed link. *)

(** [resolve ~backend ?base_domain ?override ()] resolves the base
    observability UI URL for [backend].
    - [override], when given, always wins (e.g. sol logs's
      [--grafana-base-url] flag) -- the resolver is a default, not a lock.
    - [Local] defaults to ["http://localhost:3000"].
    - [Self_hosted_durable] resolves to ["https://grafana.<base_domain>"],
      matching platform/infra/base's Grafana Ingress -- requires
      [base_domain].
    - [External] never guesses: returns [No_url _]. *)
val resolve
  :  backend:backend
  -> ?base_domain:string
  -> ?override:string
  -> unit
  -> resolution

(** [effective_backend_and_base_domain ~explicit_backend ~explicit_base_domain
    ~target ()] layers explicit CLI flags over [target]'s [sol.yml] config
    (loaded via [Sol_cli_config.load_for_target], the same path
    [sol plan]/[sol cloud tf] use) over the hardcoded [Local] default:
    - an explicit flag always wins when given;
    - otherwise, when [target] ([<env>/<provider>/<region>]) is given, its
      config supplies the backend/base_domain;
    - otherwise falls back to [Local]/[None], matching today's behavior.
    [Error _] covers: [target] fails to load, resolves to no target, or
    sets an [observability_backend] value outside
    ["local"|"self_hosted_durable"|"external"]. *)
val effective_backend_and_base_domain
  :  explicit_backend:backend option
  -> explicit_base_domain:string option
  -> target:string option
  -> unit
  -> (backend * string option, string) result
