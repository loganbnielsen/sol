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

val boundary_to_string : boundary -> string

val request_finished
  :  method_:string
  -> path:string
  -> ?route:string
  -> ?trace_id:string
  -> boundary:boundary
  -> ?workload_principal:string * string
  -> status:int
  -> duration_s:float
  -> unit
  -> event
