(** gcloud's failures, classified in one place (REFAC-136; REFAC-125's rule for
    kubectl, applied to gcloud).

    gcloud publishes no structured error for most commands, so absence is read from
    its wording -- once, here. The classification is a view for control flow; the
    message a caller reports is always gcloud's own text. *)

type reason =
  | Not_found
  | Other

(** [says_not_found ?project text]: [text] is gcloud saying the thing asked for
    does not exist. With [~project], the answer must also be *about* that project:
    GCP answers 404 both for "gone" and for "that project is not visible to you",
    so a not-found naming another project is not absence (finding C). *)
val says_not_found : ?project:string -> string -> bool

(** [classify ?project error]: [Not_found] when a non-zero gcloud exit says so,
    [Other] for everything else, including a failure to run gcloud at all. *)
val classify : ?project:string -> Sol_cli_process.error -> reason

(** The project(s) a gcloud message names, lowercased. Exposed for tests. *)
val mentioned_projects : string -> string list
