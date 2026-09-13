(* REFAC-089: the environment an execution happens in -- bound once at the
   command boundary and carried as one value from there down.

   [mode] and [secret_backend] deliberately do NOT live here. They are
   instructions for *this* execution, not properties of the world it runs in;
   folding them into the same record would be the same flattening mistake in a
   new place. *)

type context =
  { cluster : Sol_cli_kube_destination.context
  ; workspace : string
  ; env : string option
  }

let context ~cluster ~workspace ?env () = { cluster; workspace; env }
