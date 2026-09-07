type handler = Request.t -> Response.t

type pattern_segment =
  | Literal of string
  | Param of string

type pattern =
  { source         : string
  ; segments       : pattern_segment list
  ; trailing_slash : bool
  }

type t =
  { method_  : Request.method_
  ; pattern  : pattern
  ; auth     : Auth.level
  ; handler  : handler
  }

(* ── Path parsing and matching ───────────────────────────────────────────── *)

let split_path path =
  String.split_on_char '/' path |> List.filter (fun s -> s <> "")

let trailing_slash s = s <> "" && s.[String.length s - 1] = '/'

(* Parses a request path; None if malformed (consecutive slashes), else
   Some (segments, has_trailing_slash). *)
let parse_request_path path =
  let len = String.length path in
  let rec has_double_slash i =
    if i >= len - 1 then false
    else if path.[i] = '/' && path.[i + 1] = '/' then true
    else has_double_slash (i + 1)
  in
  if has_double_slash 0 then None
  else Some (split_path path, trailing_slash path)

let valid_param_name name =
  let is_start = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false
  in
  let is_rest = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  let len = String.length name in
  len > 0 && is_start name.[0] && String.for_all is_rest name

let parse_pattern source =
  let fail msg = Error (Printf.sprintf "invalid route pattern %S: %s" source msg) in
  if source = "" then fail "empty pattern"
  else if source.[0] <> '/' then fail "pattern must start with /"
  else
    match parse_request_path source with
    | None -> fail "pattern must not contain consecutive slashes"
    | Some (raw_segments, trailing_slash) ->
      let rec parse_segments acc = function
        | [] -> Ok (List.rev acc)
        | seg :: rest ->
          if String.length seg > 0 && seg.[0] = ':' then
            let name = String.sub seg 1 (String.length seg - 1) in
            if valid_param_name name then
              parse_segments (Param name :: acc) rest
            else
              fail (Printf.sprintf "invalid parameter segment %S" seg)
          else if String.contains seg ':' then
            fail (Printf.sprintf "literal segment %S must not contain :" seg)
          else
            parse_segments (Literal seg :: acc) rest
      in
      Result.map
        (fun segments -> { source; segments; trailing_slash })
        (parse_segments [] raw_segments)

let pattern source =
  match parse_pattern source with
  | Ok p -> p
  | Error msg -> invalid_arg msg

let pattern_to_string p = p.source

let make m pattern_source ~auth handler =
  { method_ = m; pattern = pattern pattern_source; auth; handler }

let get    p ~auth h = make `GET    p ~auth h
let post   p ~auth h = make `POST   p ~auth h
let put    p ~auth h = make `PUT    p ~auth h
let patch  p ~auth h = make `PATCH  p ~auth h
let delete p ~auth h = make `DELETE p ~auth h
