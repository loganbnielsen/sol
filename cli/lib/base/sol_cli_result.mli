(** What [Stdlib.Result] lacks for a [let*] chain over a list (REFAC-115). *)

(** [map_list f xs] is [Ok] of [f] applied to every element, in order, or the
    first [Error] [f] returns; elements after it are not visited. *)
val map_list : ('a -> ('b, 'e) result) -> 'a list -> ('b list, 'e) result
