val http_get
  :  ?ca_file:string
  -> _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> (int * string, string) result

val http_post
  :  ?ca_file:string
  -> _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> content_type:string
  -> body:string
  -> (int * string, string) result

val http_put
  :  ?ca_file:string
  -> _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> content_type:string
  -> body:string
  -> (int * string, string) result
