let is_blank s = String.trim s = ""
let non_blank s = if is_blank s then None else Some (String.trim s)
let non_blank_opt o = Option.bind o non_blank

let non_empty = function
  | Some "" | None -> None
  | Some _ as s -> s
;;

let env name = non_blank_opt (Sys.getenv_opt name)

let index_of ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec at i =
    if i + n > h
    then None
    else if String.equal (String.sub haystack i n) needle
    then Some i
    else at (i + 1)
  in
  at 0
;;

let contains ~needle haystack = Option.is_some (index_of ~needle haystack)

let strip_prefix_opt ~prefix s =
  if String.starts_with ~prefix s
  then Some (String.sub s (String.length prefix) (String.length s - String.length prefix))
  else None
;;

let before_opt ~needle haystack =
  Option.map (fun i -> String.sub haystack 0 i) (index_of ~needle haystack)
;;

let after_opt ~needle haystack =
  Option.map
    (fun i ->
       String.sub
         haystack
         (i + String.length needle)
         (String.length haystack - i - String.length needle))
    (index_of ~needle haystack)
;;
