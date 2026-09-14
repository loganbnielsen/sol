let run_ok = Sol_cli_process.run_ok
let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd

let buildx_available () =
  match run (cmd [ "docker"; "buildx"; "version" ]) with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false
;;

let build ~tag ~dockerfile ~context =
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
  let provenance_flags =
    if buildx_available ()
    then [ "--provenance=false"; "--sbom=false" ]
    else (
      Printf.eprintf
        "warning: docker buildx plugin not found; using the legacy builder (install \
         docker-buildx for BuildKit builds).\n\
         %!";
      [])
  in
  run_ok
    (cmd
       ([ "docker"; "build" ]
        @ provenance_flags
        @ [ "-t"; tag; "-f"; dockerfile; context ]))
;;

let push ~image_ref = run_ok (cmd [ "docker"; "push"; image_ref ])

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
