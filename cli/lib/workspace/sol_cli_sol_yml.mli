(** Editing [sol.yml]: recording what Sol knows about the workload it just
    generated, without rewriting what the operator wrote.

    [sol.yml] is hand-maintained — [`sol new`] writes the generated tree under
    [app/] and never this file — so recording a declaration means patching its
    text in place. Every comment, blank line and entry Sol did not write stays
    byte-identical, and the value Sol adds is rendered by {!Sol_cli_yaml}
    (REFAC-131) rather than interpolated into a template, so a name that needs
    quoting is quoted.

    FEAT-104: [`sol new`] records the generated workload's declared language, so
    every workload Sol creates satisfies "every workload has a declared language,
    and Sol never guesses one". A [sol.yml] this module cannot patch — a flow
    mapping, a quoted key — is refused, naming the file, rather than rewritten
    into a shape the operator did not choose. *)

type outcome =
  | Declared (** the workload had no entry; one was added with its language *)
  | Language_added (** the workload had an entry without a [language:]; it was added *)
  | Already_declared (** the entry already declares this language; nothing was written *)

(** A validated edit. [plan] reads and checks everything and writes nothing, so
    a caller can refuse before it creates any file; [commit] performs the write
    (or does nothing at all, for {!Already_declared}). *)
type plan

val outcome : plan -> outcome

(** [plan ~root ~name ~dir ~language] validates recording [name] (the workload
    declared under [services:] in [root/sol.yml]) as [language] at [dir], the
    workload's workspace-relative directory.

    Errors, all naming what is wrong and none of them writing anything:

    - [sol.yml] cannot be read or parsed (the parse error names the file and
      line);
    - [name] is already declared at a different [path] — the manifest keys
      services by bare name, so recording this one would mis-declare the other;
    - [name] is already declared with a different language from the one Sol is
      generating;
    - [sol.yml] is not a shape this module can patch in place. *)
val plan
  :  root:string
  -> name:string
  -> dir:string
  -> language:Sol_cli_compat.language
  -> (plan, string) result

(** [commit p] writes [p]'s manifest, atomically: the file is replaced by a
    complete new one, so a failure leaves the original in place. An
    {!Already_declared} plan writes nothing, not even a new modification time. *)
val commit : plan -> (outcome, string) result
