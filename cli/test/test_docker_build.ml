(* The application image build's cache argv (SOL_BUILD_CACHE_DIR).

   Pinned here because a wrong flag is invisible until it does one of two bad
   things: silently builds against different dependencies, or errors on the
   runners that have buildx (and passes on the machines that do not).

   Measured motivation: on the OCaml golden path the first app image of a run
   cost 297s (cold `opam install --deps-only`) while the three that followed
   reused its layers in seconds -- a fresh CI runner has no BuildKit cache to
   reuse. Four shapes matter, and the fourth is the one that decides whether the
   *first* run works at all:

     1. no cache            -> exactly the argv this module has always produced
     2. no buildx, no cache -> the legacy argv, without BuildKit-only flags
     3. cache + buildx      -> buildx build --load + import/export
     4. cache, directory not there yet -> export only (importing a missing
        directory is an error in BuildKit, not a cache miss) *)

let sample_argv ~buildx ~cache ~cache_present =
  Sol_cli_docker.build_argv
    ~buildx
    ~cache
    ~cache_present
    ~tag:"localhost:5000/app/svc:abc123"
    ~dockerfile:"/tmp/ctx/Dockerfile"
    ~context:"/tmp/ctx"
;;

let check_argv name expected actual = Alcotest.(check (list string)) name expected actual

let test_no_cache_keeps_the_original_argv () =
  check_argv
    "docker build, attestations off, tag/dockerfile/context last"
    [ "docker"
    ; "build"
    ; "--provenance=false"
    ; "--sbom=false"
    ; "-t"
    ; "localhost:5000/app/svc:abc123"
    ; "-f"
    ; "/tmp/ctx/Dockerfile"
    ; "/tmp/ctx"
    ]
    (sample_argv ~buildx:true ~cache:None ~cache_present:false)
;;

let test_no_buildx_omits_the_buildkit_only_flags () =
  (* FRIC-018: the legacy builder rejects --provenance outright (exit 125), and
     never attaches an attestation, so it must not be passed one. *)
  check_argv
    "legacy builder argv"
    [ "docker"
    ; "build"
    ; "-t"
    ; "localhost:5000/app/svc:abc123"
    ; "-f"
    ; "/tmp/ctx/Dockerfile"
    ; "/tmp/ctx"
    ]
    (sample_argv ~buildx:false ~cache:None ~cache_present:false)
;;

let test_cache_with_buildx_imports_and_exports () =
  check_argv
    "buildx build with --load and local cache import/export"
    [ "docker"
    ; "buildx"
    ; "build"
    ; "--load"
    ; "--provenance=false"
    ; "--sbom=false"
    ; "--cache-from"
    ; "type=local,src=/var/cache/sol-build"
    ; "--cache-to"
    ; "type=local,dest=/var/cache/sol-build,mode=max"
    ; "-t"
    ; "localhost:5000/app/svc:abc123"
    ; "-f"
    ; "/tmp/ctx/Dockerfile"
    ; "/tmp/ctx"
    ]
    (sample_argv
       ~buildx:true
       ~cache:(Some (Sol_cli_docker.Local_dir "/var/cache/sol-build"))
       ~cache_present:true)
;;

let test_first_run_exports_without_importing () =
  (* The directory exists only after the first export, so the first run on a
     machine must not try to import it. BuildKit treats an import of a missing
     local cache as an error, which would fail the build outright. *)
  let argv =
    sample_argv
      ~buildx:true
      ~cache:(Some (Sol_cli_docker.Local_dir "/var/cache/sol-build"))
      ~cache_present:false
  in
  Alcotest.(check bool)
    "no --cache-from on the first run"
    false
    (List.mem "--cache-from" argv);
  Alcotest.(check bool)
    "the export still runs, so the first run seeds the cache"
    true
    (List.mem "type=local,dest=/var/cache/sol-build,mode=max" argv)
;;

let test_cache_without_buildx_falls_back_to_a_normal_build () =
  (* A cache is an optimization: without BuildKit there is nothing to import or
     export, and the build must proceed exactly as it did before this existed. *)
  check_argv
    "no cache flags leak into the legacy argv"
    [ "docker"
    ; "build"
    ; "-t"
    ; "localhost:5000/app/svc:abc123"
    ; "-f"
    ; "/tmp/ctx/Dockerfile"
    ; "/tmp/ctx"
    ]
    (sample_argv
       ~buildx:false
       ~cache:(Some (Sol_cli_docker.Local_dir "/var/cache/sol-build"))
       ~cache_present:true)
;;

let test_env_names_the_cache_location () =
  let of_env =
    Sol_cli_docker.cache_of_env ~lookup:(fun name ->
      if name = "SOL_BUILD_CACHE_DIR" then None else None)
  in
  Alcotest.(check bool) "unset means no cache" true (of_env () = None);
  let empty = Sol_cli_docker.cache_of_env ~lookup:(fun _ -> Some "   ") in
  Alcotest.(check bool) "blank means no cache" true (empty () = None);
  let set =
    Sol_cli_docker.cache_of_env ~lookup:(fun _ -> Some " /var/cache/sol-build\n ")
  in
  Alcotest.(check bool)
    "set and trimmed"
    true
    (set () = Some (Sol_cli_docker.Local_dir "/var/cache/sol-build"))
;;

(* The fallback policy: a cache must never be the reason a deploy cannot happen,
   and an ordinary build failure must never be silently rebuilt. Both messages
   below are real: the first is captured from CI, the second is what a normal
   build failure looks like. *)
let captured_driver_error =
  Sol_cli_process.Non_zero
    { exit_code = 1
    ; stderr =
        "ERROR: failed to build: Cache export is not supported for the docker driver.\n\
         Switch to a different driver, or turn on the containerd image store, and try \
         again."
    }
;;

let compile_error =
  Sol_cli_process.Non_zero
    { exit_code = 1; stderr = "Error: dune build failed: Unbound module Sol_cli_missing" }
;;

let test_cache_export_unsupported_is_retried_without_one () =
  let cache = Some (Sol_cli_docker.Local_dir "/var/cache/sol-build") in
  Alcotest.(check bool)
    "a driver that cannot export cache -> rebuild without one"
    true
    (Sol_cli_docker.cache_failure_disposition cache captured_driver_error
     = Sol_cli_docker.Retry_without_cache)
;;

let test_other_failures_are_reported () =
  let cache = Some (Sol_cli_docker.Local_dir "/var/cache/sol-build") in
  Alcotest.(check bool)
    "an ordinary build failure is reported, not retried"
    true
    (Sol_cli_docker.cache_failure_disposition cache compile_error = Sol_cli_docker.Report);
  Alcotest.(check bool)
    "a spawn failure is reported"
    true
    (Sol_cli_docker.cache_failure_disposition
       cache
       (Sol_cli_process.Spawn_failed "no docker")
     = Sol_cli_docker.Report)
;;

let test_no_cache_means_nothing_to_retry () =
  Alcotest.(check bool)
    "with no cache configured there is no fallback"
    true
    (Sol_cli_docker.cache_failure_disposition None captured_driver_error
     = Sol_cli_docker.Report)
;;

let () =
  Alcotest.run
    "docker_build"
    [ ( "argv"
      , [ Alcotest.test_case "no cache" `Quick test_no_cache_keeps_the_original_argv
        ; Alcotest.test_case
            "no buildx"
            `Quick
            test_no_buildx_omits_the_buildkit_only_flags
        ; Alcotest.test_case
            "cache and buildx"
            `Quick
            test_cache_with_buildx_imports_and_exports
        ; Alcotest.test_case
            "cache without a directory yet"
            `Quick
            test_first_run_exports_without_importing
        ; Alcotest.test_case
            "cache without buildx"
            `Quick
            test_cache_without_buildx_falls_back_to_a_normal_build
        ] )
    ; ( "env"
      , [ Alcotest.test_case
            "SOL_BUILD_CACHE_DIR"
            `Quick
            test_env_names_the_cache_location
        ] )
    ; ( "fallback"
      , [ Alcotest.test_case
            "driver cannot export"
            `Quick
            test_cache_export_unsupported_is_retried_without_one
        ; Alcotest.test_case "other failures" `Quick test_other_failures_are_reported
        ; Alcotest.test_case "no cache" `Quick test_no_cache_means_nothing_to_retry
        ] )
    ]
;;
