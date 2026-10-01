let interactive () = Unix.isatty Unix.stdin && Unix.isatty Unix.stdout

let recognize ~default answer =
  match String.lowercase_ascii (String.trim answer) with
  | "" -> default
  | "y" | "yes" -> true
  | "n" | "no" -> false
  | _ -> false
;;

let ask ~question ~default =
  Printf.printf "%s [%s] %!" question (if default then "Y/n" else "y/N");
  match input_line stdin with
  | answer -> recognize ~default answer
  | exception End_of_file -> false
;;
