let trigger = Fn.Cron

let run () =
  Printf.printf "[{{name}}-fn] running\n%!";
  Ok ()
