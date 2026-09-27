let cmd = Sol_cli_process.cmd

let buildx_available () =
  Result.is_ok (Sol_cli_process.run (cmd [ "docker"; "buildx"; "version" ]))
;;

let build ~tag ~dockerfile ~context =
  let provenance_flags =
    if buildx_available ()
    then [ "--provenance=false"; "--sbom=false" ]
    else (
      Sol_cli_report.warn
        "warning: docker buildx plugin not found; using the legacy builder (install \
         docker-buildx for BuildKit builds).";
      [])
  in
  Sol_cli_process.run
    (cmd
       ([ "docker"; "build" ]
        @ provenance_flags
        @ [ "-t"; tag; "-f"; dockerfile; context ]))
  |> Result.map ignore
;;

let push ~image_ref =
  Sol_cli_process.run (cmd [ "docker"; "push"; image_ref ]) |> Result.map ignore
;;

let manifest_exists ~image_ref =
  Result.is_ok (Sol_cli_process.run (cmd [ "docker"; "manifest"; "inspect"; image_ref ]))
;;

let inspect_digest ~image_ref =
  match
    Sol_cli_process.run
      (cmd [ "docker"; "inspect"; "--format"; "{{index .RepoDigests 0}}"; image_ref ])
  with
  | Ok { stdout = digest; _ } when digest <> "" && digest <> "<no value>" -> digest
  | _ -> image_ref
;;
