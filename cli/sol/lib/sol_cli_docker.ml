let run_ok = Sol_cli_process.run_ok
let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd

let build ~tag ~dockerfile ~context =
  (* --provenance=false --sbom=false: BuildKit attaches a provenance/SBOM
     attestation sub-manifest to the image index by default since Docker 23+.
     Confirmed live (DOGFOOD-011) that EKS's containerd fails to pull an
     image built without these flags with a bare "not found" error on the
     tagged reference, even though the image genuinely exists in ECR --
     the multi-manifest index confuses resolution. Local k3d/containerd
     tolerates it, which is why this was invisible before a real cloud
     cluster was involved. *)
  run_ok
    (cmd
       [
         "docker";
         "build";
         "--provenance=false";
         "--sbom=false";
         "-t";
         tag;
         "-f";
         dockerfile;
         context;
       ])

let push ~image_ref = run_ok (cmd [ "docker"; "push"; image_ref ])

let inspect_digest ~image_ref =
  match
    run
      (cmd
         [
           "docker";
           "inspect";
           "--format";
           "{{index .RepoDigests 0}}";
           image_ref;
         ])
  with
  | Ok r
    when r.Sol_cli_process.exit_code = 0
         && r.Sol_cli_process.stdout <> ""
         && r.Sol_cli_process.stdout <> "<no value>" ->
      r.Sol_cli_process.stdout
  | _ -> image_ref
