(** The environment one execution happens in (REFAC-089).

    [cluster] is *where*, [workspace] is *whose*, [env] is *which environment*
    (the label the executed objects carry). These three travel together through
    the executor and factory, so they travel as one value.

    [mode] and [secret_backend] are deliberately absent: they are instructions
    for this particular execution, and callers pass them alongside. *)

type context =
  { cluster : Sol_cli_kube_destination.context
  ; workspace : string
  ; env : string option
  }

val context
  :  cluster:Sol_cli_kube_destination.context
  -> workspace:string
  -> ?env:string
  -> unit
  -> context
