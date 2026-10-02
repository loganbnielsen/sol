let secret_capability = "secret"
let annotation_key = "sol.dev/grants"
let tag ~capability ~resource = capability ^ "/" ^ resource
let tag_of_secret_key key = tag ~capability:secret_capability ~resource:key

let split_tag tag =
  match String.index_opt tag '/' with
  | None -> "", tag
  | Some i -> String.sub tag 0 i, String.sub tag (i + 1) (String.length tag - i - 1)
;;

let capability_of_tag value = fst (split_tag value)
let resource_of_tag value = snd (split_tag value)

let encode_tags tags =
  `List (List.map (fun tag -> `String tag) tags) |> Yojson.Safe.to_string
;;

let decode_tags value =
  match Yojson.Safe.from_string value with
  | `List items ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | `String tag :: rest -> collect (tag :: acc) rest
      | _ :: _ -> Error "grant annotation must be a JSON array of strings"
    in
    collect [] items
  | _ -> Error "grant annotation must be a JSON array of strings"
  | exception Yojson.Json_error message ->
    Error ("grant annotation is not JSON: " ^ message)
;;
