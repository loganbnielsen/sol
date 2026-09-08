type method_ = [ `GET | `POST | `PUT | `PATCH | `DELETE ]

type t =
  { method_    : method_
  ; path       : string
  ; headers    : Http.Header.t
  ; params     : (string * string) list
  ; uri        : Uri.t
  ; body       : string
  ; auth       : Auth.context
  ; trace_ctx  : Obs_trace.t option
  }

let param     req key = List.assoc_opt key req.params
let param_exn req key = List.assoc     key req.params

let query_param req key = Uri.get_query_param req.uri key

let query_params req key =
  Uri.query req.uri
  |> List.filter_map (fun (k, vs) -> if k = key then Some vs else None)
  |> List.flatten

let header req name = Http.Header.get req.headers name
