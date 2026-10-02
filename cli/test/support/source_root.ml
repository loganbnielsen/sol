let marker = Filename.concat "examples" (Filename.concat "pluto" "sol.yml")

let find () =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir marker)
    then dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then
        failwith
          (Printf.sprintf
             "cannot find the sol source root (no %s) above %s"
             marker
             (Sys.getcwd ()))
      else up parent)
  in
  up (Filename.dirname Sys.executable_name)
;;
