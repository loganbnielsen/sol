let error_code text =
  match String.index_opt text '(' with
  | None -> None
  | Some open_ ->
    (match String.index_from_opt text (open_ + 1) ')' with
     | Some close when close > open_ + 1 ->
       Some (String.sub text (open_ + 1) (close - open_ - 1))
     | _ -> None)
;;
