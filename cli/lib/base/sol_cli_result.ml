let map_list f xs =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | x :: rest ->
      (match f x with
       | Ok y -> go (y :: acc) rest
       | Error _ as e -> e)
  in
  go [] xs
;;
