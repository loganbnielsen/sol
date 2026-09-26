let run_ok = Sol_cli_process.run_ok
let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd

let buildx_available () =
  match run (cmd [ "docker"; "buildx"; "version" ]) with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false
;;

(* Application image builds may reuse BuildKit cache.

   Why this is a capability here and not CI policy: the expensive part of a
   scaffolded app's image is the dependency layer (`COPY *.opam` then
   `opam install --deps-only .`), and a fresh CI runner has no BuildKit cache of
   its own -- measured on the OCaml golden path: the first image of the run cost
   297s while the three that followed reused its layers in seconds. Sol supplies
   the ability to import/export cache; whoever runs the build decides whether a
   cache survives between runs (CI persists this directory in its own cache;
   a developer who wants one points this at a directory they keep).

   Correctness never depends on the cache: with no cache configured the argv is
   exactly what it was before, a cache that is missing or stale only means a
   normal rebuild (BuildKit keys every layer on its inputs, so a changed
   Dockerfile or `.opam` invalidates the dependency layer by construction), and
   an environment without the buildx plugin builds exactly as it did before. *)
type cache = Local_dir of string

let cache_dir_env = "SOL_BUILD_CACHE_DIR"

let cache_of_env ?(lookup = Sys.getenv_opt) () =
  match lookup cache_dir_env with
  | Some dir when String.trim dir <> "" -> Some (Local_dir (String.trim dir))
  | Some _ | None -> None
;;

(* BuildKit's attestation flags: see [build] below for why they exist. *)
let attestation_flags = [ "--provenance=false"; "--sbom=false" ]

(* [build_argv] is pure so the shapes can be pinned without docker: the exact
   argv is what a wrong cache flag would break, and a wrong cache flag is the
   difference between "reused the dependency layer" and "silently deployed
   different dependencies". *)
let build_argv ~buildx ~cache ~cache_present ~tag ~dockerfile ~context =
  match cache with
  | Some (Local_dir dir) when buildx ->
    (* `--load` matters: `docker buildx build` does not put the image into the
       local image store by default, and `sol up` pushes it with `docker push`
       immediately afterwards. Verified against the docker driver (buildx
       0.30.1): `--load`, `--cache-from type=local,src=...` and
       `--cache-to type=local,dest=...,mode=max` all work there, and a build on
       a pruned builder reuses the dependency layer while rebuilding the layers
       that copy application sources.

       `mode=max` is required, not cosmetic: the dependency install happens in
       the Dockerfile's build stage, and `mode=min` would export only the final
       image's layers -- the expensive ones are intermediates.

       `--cache-from` is omitted when the directory does not exist yet (the
       first run on a machine), because an import from a missing directory is an
       error, not a cache miss. The export still runs, so that run seeds it. *)
    let import =
      if cache_present then [ "--cache-from"; "type=local,src=" ^ dir ] else []
    in
    [ "docker"; "buildx"; "build"; "--load" ]
    @ attestation_flags
    @ import
    @ [ "--cache-to"; "type=local,dest=" ^ dir ^ ",mode=max" ]
    @ [ "-t"; tag; "-f"; dockerfile; context ]
  | Some (Local_dir _) | None ->
    (* No cache, or no buildx: byte-identical to the argv this module has always
       produced. The legacy builder (FRIC-018) rejects the attestation flags, so
       they are omitted there too -- it never attaches an attestation. *)
    [ "docker"; "build" ]
    @ (if buildx then attestation_flags else [])
    @ [ "-t"; tag; "-f"; dockerfile; context ]
;;

let build ?cache ~tag ~dockerfile ~context () =
  (* --provenance=false --sbom=false: BuildKit attaches a provenance/SBOM
     attestation sub-manifest to the image index by default since Docker 23+.
     Confirmed live (DOGFOOD-011) that EKS's containerd fails to pull an
     image built without these flags with a bare "not found" error on the
     tagged reference, even though the image genuinely exists in ECR --
     the multi-manifest index confuses resolution. Local k3d/containerd
     tolerates it, which is why this was invisible before a real cloud
     cluster was involved.

     FRIC-018: those flags are only meaningful (and only accepted) by BuildKit.
     Ubuntu's `docker.io` package ships no `buildx` plugin, so `docker build`
     falls back to the legacy builder, which rejects the flags outright
     ("unknown flag: --provenance", exit 125) before building anything. The
     legacy builder never attaches an attestation in the first place, so omit
     the flags in that case -- `sol up` then works on a stock Docker install,
     and the EKS fix is preserved wherever BuildKit is actually in use. *)
  let buildx = buildx_available () in
  if not buildx
  then
    Printf.eprintf
      "warning: docker buildx plugin not found; using the legacy builder (install \
       docker-buildx for BuildKit builds).\n\
       %!";
  let cache =
    match cache with
    | Some c -> Some c
    | None -> cache_of_env ()
  in
  (match cache, buildx with
   | Some (Local_dir _), false ->
     Printf.eprintf
       "warning: %s is set but the buildx plugin is missing; building without a \
        persistent build cache.\n\
        %!"
       cache_dir_env
   | Some (Local_dir _), true | None, _ -> ());
  let cache_present =
    match cache with
    | Some (Local_dir dir) -> Sys.file_exists dir
    | None -> false
  in
  run_ok (cmd (build_argv ~buildx ~cache ~cache_present ~tag ~dockerfile ~context))
;;

let push ~image_ref = run_ok (cmd [ "docker"; "push"; image_ref ])

(* FEAT-050: confirm a supplied digest reference actually exists in its
   registry before anything is applied. [docker manifest inspect] resolves the
   reference against the registry (using the already-configured docker
   credentials) and exits non-zero when it cannot. A reference that does not
   exist is a caller error, not a transient one, so the caller treats a false
   result as fail-closed. *)
let manifest_exists ~image_ref =
  match run (cmd [ "docker"; "manifest"; "inspect"; image_ref ]) with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false
;;

let inspect_digest ~image_ref =
  match
    run (cmd [ "docker"; "inspect"; "--format"; "{{index .RepoDigests 0}}"; image_ref ])
  with
  | Ok r
    when r.Sol_cli_process.exit_code = 0
         && r.Sol_cli_process.stdout <> ""
         && r.Sol_cli_process.stdout <> "<no value>" -> r.Sol_cli_process.stdout
  | _ -> image_ref
;;
