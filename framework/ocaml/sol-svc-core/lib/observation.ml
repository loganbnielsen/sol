type boundary =
  | Internal
  | External

type request =
  { method_ : string
  ; path : string
  ; route : string option
  ; trace_id : string option
  ; boundary : boundary
  ; workload_principal : (string * string) option
  ; status : int
  ; duration_s : float
  }

type event = Request_finished of request
type sink = event -> unit

let boundary_to_string = function
  | Internal -> "internal"
  | External -> "external"
;;

let request_finished
      ~method_
      ~path
      ?route
      ?trace_id
      ~boundary
      ?workload_principal
      ~status
      ~duration_s
      ()
  =
  Request_finished
    { method_; path; route; trace_id; boundary; workload_principal; status; duration_s }
;;
