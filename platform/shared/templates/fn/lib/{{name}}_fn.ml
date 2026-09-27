(* The schedule lives in this workload's sol.toml ([service] schedule). *)
let trigger = Fn.Cron

let run () =
  Printf.printf "[{{name}}-fn] running\n%!";
  Ok ()
