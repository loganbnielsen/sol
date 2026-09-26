(** Where an application image build may import and export BuildKit cache.

    [Local_dir d] is a directory that survives between builds: its contents are
    imported as cache input when it exists, and exported in full ([mode=max], so
    the Dockerfile's build-stage layers are included) after every build. *)
type cache = Local_dir of string

(** The cache directory named by [SOL_BUILD_CACHE_DIR], if it is set and
    non-empty. Unset means no cache, and the build then behaves exactly as it did
    before this existed. The variable names a cache *location* only -- whether
    anything persists it between runs is the caller's business, which is how CI
    persists it without Sol knowing anything about CI. *)
val cache_of_env : ?lookup:(string -> string option) -> unit -> cache option

(** The docker argv for a build, without running it.

    - no cache (or no buildx): the argv this module has always produced;
    - cache and buildx: [docker buildx build --load] with
      [--cache-from type=local,src=DIR] when the directory exists, and
      [--cache-to type=local,dest=DIR,mode=max]. [--load] is load-bearing: the
      image must land in the local image store because callers push it with
      [docker push].

    Pure, so the shapes can be pinned by tests. *)
val build_argv
  :  buildx:bool
  -> cache:cache option
  -> cache_present:bool
  -> tag:string
  -> dockerfile:string
  -> context:string
  -> string list

(** What to do when a build with a configured cache fails: [Retry_without_cache]
    when the driver cannot export cache (BuildKit says so itself), [Report]
    otherwise -- an ordinary build failure must not be silently rebuilt. *)
type cache_failure =
  | Retry_without_cache
  | Report

(** The decision behind the fallback, pure so the captured driver message can be
    a test fixture. [Report] whenever no cache was configured. *)
val cache_failure_disposition : cache option -> Sol_cli_process.error -> cache_failure

(** [build ?cache ~tag ~dockerfile ~context ()] builds the image; [cache]
    defaults to [cache_of_env ()] and, if the driver cannot export cache, the
    build is retried once without one (a cache is an optimization, never the
    reason a deploy cannot happen). The trailing unit is required by OCaml's
    optional-argument erasure rules, as it is for this repo's other optional
    arguments. *)
val build
  :  ?cache:cache
  -> tag:string
  -> dockerfile:string
  -> context:string
  -> unit
  -> (unit, Sol_cli_process.error) result

val push : image_ref:string -> (unit, Sol_cli_process.error) result

(** [manifest_exists ~image_ref] is true when the registry resolves
    [image_ref] (a digest or tag) through `docker manifest inspect`. A missing
    reference, a missing docker CLI, or a registry/credential failure all
    return false: the caller fails closed. *)
val manifest_exists : image_ref:string -> bool

val inspect_digest : image_ref:string -> string
