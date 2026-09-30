let candidates () =
  let rec up levels path =
    if levels = 0 then path else up (levels - 1) (Filename.dirname path)
  in
  let dir = Filename.dirname Sys.executable_name in
  List.init 7 (fun levels -> Filename.concat (up levels dir) "cli/bin/main.exe")
;;

let path () =
  match List.find_opt Sys.file_exists (candidates ()) with
  | Some binary -> binary
  | None ->
    failwith
      "the built sol binary is not beside this test runner: the inline test library must \
       declare (deps ../../bin/main.exe) so dune builds it before the tests run"
;;
