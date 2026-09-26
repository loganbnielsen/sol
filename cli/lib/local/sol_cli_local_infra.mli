(* The install phase of `sol local infra up`, with bounded concurrency.

   Seven Helm releases that do not depend on each other -- Redpanda, PostgreSQL,
   Loki, Grafana, Tempo, Prometheus, ingress-nginx -- used to be installed one
   after another, each blocking on its own pods: measured ~290s of every golden
   path, in both languages, and the same 290s in a developer's first `sol local
   infra up`.

   Their install-time dependencies are only the cluster and the Helm
   repositories. Grafana's datasource ConfigMaps are applied by the caller *after*
   these return, and the port-forwards after that, so nothing in this list has to
   wait for anything else in it. That is the whole claim this module makes; it is
   not a general workflow engine.

   Bounded, not unbounded: a k3d cluster is one node, so seven concurrent
   `helm --wait` installs would contend for the same node's image pulls and CPU,
   and a stuck component would be harder to attribute. Three in flight keeps the
   overlap in the part that is actually idle (waiting for pods) without turning
   the node into the bottleneck.

   Children are forked rather than threaded on purpose. Each install is an
   external `helm` process whose helper exits the process on failure, and a forked
   child contains that: a failed install cannot take the parent -- or its
   siblings -- down with it, and the parent decides what to report. *)

(** One component's install: a name for the log, and the work. [run] must not
    call [exit]; returning [Error] is how a component fails. *)
type install =
  { label : string
  ; run : unit -> (unit, string) result
  }

val max_in_flight_default : int

(** Install every component, at most [max_in_flight] at a time (default
    [max_in_flight_default]).

    Each child writes its own output to its own file, so a component's log is
    attributable even when three are running; the parent prints one progress line
    per component, and the full output of any component that failed.

    The first failure stops *new* installs from starting, but the ones already
    running are waited for rather than abandoned, and every failure is reported
    in plan order -- a component that never ran says so instead of appearing to
    have succeeded. *)
val run_bounded : ?max_in_flight:int -> install list -> (unit, string) result
