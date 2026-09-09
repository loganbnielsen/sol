module Severity : sig
  type t = Error | Warning
end

type finding = {
  severity : Severity.t;
  path     : string;
  message  : string;
}

val finding_to_string : finding -> string
val run : filter_path:string option -> unit -> finding list
val has_errors : finding list -> bool
