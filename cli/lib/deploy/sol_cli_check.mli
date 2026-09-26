(** Shared pre-deploy contract check for every command that ships workloads
    ([sol check], [sol up], [sol deploy]).

    This phase is intentionally static: it validates workspace shape and files
    without requiring Kubernetes or a running container. It checks service
    directories, Dockerfiles, [sol.toml] parse errors, secret-key validity, and
    primitive/schedule shape, and reports actionable findings that reference the
    offending service path.

    Runtime endpoints are intentionally out of scope. [GET /healthz] and
    [GET /metrics] are guaranteed by the service/worker frameworks (see
    [Sol_svc.Service] and [Sol_worker.Worker]); a user's own source may not
    mention them at all. Verifying those endpoints requires a post-deploy smoke
    probe against a running workload, not a static pre-deploy check. *)
module Severity : sig
  type t =
    | Error
    | Warning
end

type finding =
  { severity : Severity.t
  ; path : string
  ; message : string
  }

val finding_to_string : finding -> string

(** Check the whole workspace: scan it, warn about unexpected directories, and
    error when no deployable workload exists. *)
val run : unit -> finding list

(** Check exactly the given workloads, without rescanning the workspace. Commands
    that resolved a [--scope] pass the resolved set here so the contract check
    covers the same set they are about to mutate. *)
val run_services : Sol_cli_manifest.service list -> finding list

val has_errors : finding list -> bool
