let is_blank s = String.trim s = ""
let non_blank s = if is_blank s then None else Some (String.trim s)
let non_blank_opt o = Option.bind o non_blank

let non_empty = function
  | Some "" | None -> None
  | Some _ as s -> s
;;

let env name = non_empty (Sys.getenv_opt name)

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  at 0
;;
