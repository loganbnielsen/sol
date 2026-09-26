(** UTC timestamps, formatted from a Unix time in seconds (REFAC-119).

    One place for the formats Sol writes, over [ptime], so no caller decodes a
    C [struct tm] (years since 1900, zero-based months). All are second
    precision (a fraction is truncated) and sort lexicographically in time
    order. *)

(** [2026-09-26T15:30:49Z]: RFC 3339. *)
val rfc3339 : float -> string

(** [20260926T153049Z]: compact, for run and operation directory names. *)
val compact : float -> string

(** [20260926t153049z]: compact with lowercase separators, for identifiers that
    must be valid Kubernetes names. *)
val compact_lower : float -> string
