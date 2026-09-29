type ('lease, 'boundary, 'result, 'error) deps =
  { acquire_lease : ('lease -> ('result, 'error) result) -> ('result, 'error) result
  ; read_boundary_holding : 'lease -> ('boundary, 'error) result
  ; apply : 'lease -> 'boundary -> ('result, 'error) result
  }

val run : ('lease, 'boundary, 'result, 'error) deps -> ('result, 'error) result
