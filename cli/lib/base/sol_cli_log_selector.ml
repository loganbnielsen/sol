type t =
  { workspace : string
  ; domain : string
  ; service : string
  }

let pair label value = Printf.sprintf {|%s="%s"|} label value

let identity (t : t) =
  [ "workspace", Sol_cli_kubernetes_name.sanitize_label_value t.workspace
  ; "domain", Sol_cli_kubernetes_name.sanitize_label_value t.domain
  ; "service", Sol_cli_kubernetes_name.sanitize_label_value t.service
  ]
  |> List.map (fun (label, value) -> pair label value)
;;

let selector pairs = "{" ^ String.concat ", " pairs ^ "}"
let unit (t : t) = selector (identity t)

let unit_release (t : t) ~release_id =
  selector (identity t @ [ pair "release" release_id ])
;;
