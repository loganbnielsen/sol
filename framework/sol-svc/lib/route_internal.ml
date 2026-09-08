let match_path (pattern : Route.pattern) request_path =
  match Route.parse_request_path request_path with
  | None -> None
  | Some (req_segs, req_ts) ->
    if pattern.Route.trailing_slash <> req_ts then None
    else
      let rec go pats reqs acc =
        match pats, reqs with
        | [], []       -> Some (List.rev acc)
        | Route.Param key :: ps, r :: rs ->
          go ps rs ((key, Uri.pct_decode r) :: acc)
        | Route.Literal p :: ps, r :: rs ->
          if p = r then go ps rs acc else None
        | _ -> None
      in
      go pattern.Route.segments req_segs []

let method_of_http : Http.Method.t -> Request.method_ option = function
  | `GET    -> Some `GET
  | `POST   -> Some `POST
  | `PUT    -> Some `PUT
  | `PATCH  -> Some `PATCH
  | `DELETE -> Some `DELETE
  | _       -> None
