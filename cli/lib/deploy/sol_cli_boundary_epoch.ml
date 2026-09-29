type ('lease, 'boundary, 'result, 'error) deps =
  { acquire_lease : ('lease -> ('result, 'error) result) -> ('result, 'error) result
  ; read_boundary_holding : 'lease -> ('boundary, 'error) result
  ; apply : 'lease -> 'boundary -> ('result, 'error) result
  }

let run deps =
  deps.acquire_lease (fun lease ->
    match deps.read_boundary_holding lease with
    | Error _ as error -> error
    | Ok boundary -> deps.apply lease boundary)
;;
