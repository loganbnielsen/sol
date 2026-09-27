val http_get
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> (int * string, string) result

val http_post
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> content_type:string
  -> body:string
  -> (int * string, string) result

val http_put
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> content_type:string
  -> body:string
  -> (int * string, string) result
