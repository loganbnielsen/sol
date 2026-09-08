type body_request =
  { content_type : string
  ; body : string
  }

type request =
  | Get of { base_url : string; path : string }
  | With_body of
      { meth : [ `POST | `PUT ]
      ; base_url : string
      ; path : string
      ; body_request : body_request
      }

let http_do net ~clock request =
  let meth, url, headers, body =
    match request with
    | Get { base_url; path } ->
      ( `GET
      , base_url ^ path
      , [ ("Accept", "application/json"); ("Connection", "close") ]
      , None )
    | With_body { meth; base_url; path; body_request = { content_type; body } } ->
      ( (meth :> Http.Method.t)
      , base_url ^ path
      , [ ("Accept", "application/json"); ("Connection", "close"); ("Content-Type", content_type) ]
      , Some body )
  in
  Https_eio.request ~net ~clock ~timeout:10.0 ~meth ~url ~headers ?body
    ~max_response_bytes:(4 * 1024 * 1024) ()
  |> Result.map_error (fun e -> "kafka_service: " ^ Https_eio.request_error_to_string e)

let http_post net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock
    (With_body
       { meth = `POST
       ; base_url
       ; path
       ; body_request = { content_type; body }
       })

let http_put net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock
    (With_body
       { meth = `PUT
       ; base_url
       ; path
       ; body_request = { content_type; body }
       })

let http_get net ~clock ~base_url ~path =
  http_do net ~clock (Get { base_url; path })
