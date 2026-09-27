type context =
  { cluster : Sol_cli_kube_destination.context
  ; workspace : string
  ; env : string option
  }

let context ~cluster ~workspace ?env () = { cluster; workspace; env }
