(** OBS-043: the provider-neutral alert-delivery contract.

    A production target must name an accountable owner, a first-response runbook
    and a configured alert receiver. The receiver vocabulary is deliberately
    provider-neutral: Sol validates and wires *a* receiver, and one concrete
    adapter (a generic webhook) is the maturity-A reference mechanism. Slack,
    PagerDuty and email are adapters over the same contract, not the contract
    itself — DEC-026 §8 makes "requiring PagerDuty specifically" a non-goal, and
    OBS-043 forbids a vendor becoming the Sol-level semantic.

    This module owns only the vocabulary and the pure validation predicates.
    Reading the declaration from a target and deciding whether the guarantee is
    established live in {!Sol_cli_profile_preflight} (and the target file in
    {!Sol_cli_config}); the synthetic-delivery path lives in [sol alert test].
    Actual delivered-and-acknowledged evidence belongs to HARDEN-002. *)

(** The receiver types Sol can wire end-to-end today. [webhook] is the only
    maturity-A-qualified type; it is the reference adapter that keeps the public
    contract provider-neutral. *)
val qualified_receiver_types : string list

(** [receiver_type_qualified type_] is [true] when [type_] (case-insensitive,
    trimmed) names a receiver Sol actually wires. An unqualified *syntactic*
    type is a target error, not a silent no-op. *)
val receiver_type_qualified : string -> bool

(** [url_is_routable url] is a syntactic check that the receiver endpoint is an
    HTTP(S) URL with a host — the strongest claim Sol can make without
    delivering anything. It is deliberately not "is reachable": reachability and
    acknowledgement are the HARDEN-002 synthetic-delivery evidence, not
    something preflight can assert. *)
val url_is_routable : string -> bool

(** [validate ~receiver_type ~receiver_url ~owner ~runbook_url] is the single
    description of what a target must declare. [Error] carries the operator-facing
    reason (which declaration is missing or invalid). *)
val validate
  :  receiver_type:string option
  -> receiver_url:string option
  -> owner:string option
  -> runbook_url:string option
  -> (unit, string) result
