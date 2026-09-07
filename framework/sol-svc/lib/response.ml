type t =
  { status  : int
  ; headers : (string * string) list
  ; body    : string
  }

let ok ?(headers=[]) body         = { status = 200; headers; body }
let created ?(headers=[]) body    = { status = 201; headers; body }
let no_content                    = { status = 204; headers = []; body = "" }

let bad_request msg    = { status = 400; headers = ["content-type","text/plain"]; body = msg }
let unauthorized       = { status = 401; headers = []; body = "" }
let forbidden          = { status = 403; headers = []; body = "" }
let not_found          = { status = 404; headers = []; body = "" }
let unprocessable msg  = { status = 422; headers = ["content-type","text/plain"]; body = msg }
let payload_too_large  = { status = 413; headers = []; body = "Payload Too Large" }
let internal_error msg = { status = 500; headers = ["content-type","text/plain"]; body = msg }

let json ?(status=200) ?(headers=[]) body =
  { status; headers = ("content-type","application/json") :: headers; body }
