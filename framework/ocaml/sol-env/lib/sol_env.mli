type ('env, 'net, 'clock, 'mono) timed =
  < net : 'net Eio.Net.t
  ; clock : 'clock Eio.Time.clock
  ; mono_clock : 'mono Eio.Time.Mono.t
  ; .. >
  as
  'env
