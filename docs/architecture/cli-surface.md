# The `sol` CLI surface (target)

**Status: the target, not the current surface.** This page states the surface `sol` is
converging on, and the model that produces it. [`docs/reference/cli.md`](../reference/cli.md)
is the *current* surface, generated from the binary; § 5 diffs the two. Writing this page
down changes nothing — **the diff is the work list**, and nothing here should be
implemented until the model is agreed.

## 1. The subject rule

Every `sol` invocation has exactly **one subject**: the entity the command acts on or
reports as an instance. The subject is the **positional** argument. Anything that locates,
narrows or qualifies it is a **flag**.

> **Subject rule.** Put the thing the command is about in the positional. When the
> *target* is the subject, the target is the positional — `sol destroy <target>`. When
> the target merely *qualifies* another subject, it is `--target` —
> `sol logs payments/checkout-svc --target dev/aws/us-east-1`. When the verb names **no
> instance at all** (a listing, or a whole-workspace verb), there is **no positional**,
> and the target selects what is listed: `sol releases --target <target>`.

Two consequences worth stating outright, because each is the answer to a question that has
been decided per-PR instead of once:

- **A command never spells its subject twice.** Taking both `<target>` and `--target` is
  wrong by construction, not a style preference.
- **A required qualifier is still a qualifier.** `--target` is *required* on several
  commands that name no target-shaped instance (the help says "Required unless you use the
  `sol local <command>` form"). Requirement does not promote a flag to a positional; the
  positional means "the instance this verb acts on", and for a listing there is none.

## 2. The three subjects

| subject | spelling | what it is |
|---|---|---|
| **target** | `<env>/<provider>/<region>` | where a deployment lives — `dev/aws/us-east-1` |
| **scope** | `domain`, `domain/unit`, `resource/<type>/<name>` | what part of the application |
| **workspace object** | a release id, a secret key, a component being created | what the verb acts on in the workspace |

A **target is not a scope**, and a scope is not a narrowing of a target: they are
different subjects, read from different authorities (`DEC-032`). A command has one
subject; the other appears as a flag only where it genuinely qualifies it —
`sol status <scope> --target <target>` has a scope subject and a target qualifier, and
`sol open infra --target <target>` has no application scope at all (passing one fails
naming the view target-scoped, rather than being ignored).

The environment is a property of the target: there is no `--env` and no ambient current
target (`DEC-016`). `--target` always names a target; it never means "the current one".

### Address grammar

```
sol <verb>          <instance>                  # the subject is a target or another instance
sol <verb>          [<scope>] --target <t>      # a scope instance, qualified by a target
sol <verb>          --target <t>                # a listing: no instance, target selects
sol <family> <verb> [<instance>] [--target <t>]
```

Exactly one of `<target>` / `<scope>` / `<instance>` is positional — whichever is the
subject.

## 3. Where a command lives

Two rules, and nothing else:

1. **Target-addressed commands are top-level, and the target is their positional.**
   There is **no `sol target` noun group**: the target is the addressing axis, not an
   object the path has to name, and `sol target show <target>` spells the subject twice.
   This covers the lifecycle verbs (`plan`, `deploy`, `destroy`, `uninstall`, and the
   future `export` and `detach`) and the target's own report (`show`, `reconcile`) —
   the spellings #1302 already names.
2. **Everything else is a family, a scope-addressed verb, or a workspace verb.**
   - A **family** groups an object with more than one operation: `sol new …`,
     `sol secret …`, `sol migrate …`, `sol grants …`, `sol open …`, `sol ci …`,
     `sol contract …`, `sol local …`.
   - A **scope-addressed verb** takes its instance (a scope) positionally and the target
     as `--target`: `sol status`, `sol logs`, `sol check`, `sol open …`.
   - A **listing or workspace verb** has no instance and takes the target (if any) as
     `--target`: `sol releases`, `sol deployments`, `sol secret list`, `sol alert test`,
     `sol rollback`, `sol fn run`, `sol up`, `sol assets`.

`sol local …` is the local cluster's family: there is no target, so `--target` is an
error there rather than a silently ignored flag.

### Deliberate alternatives considered

- **A `sol target <verb> <target>` group** (the shape that landed with #1306's
  `sol target reconcile`). Rejected: the object type is already the positional, the group
  would have to grow to own `export`/`detach`, and it splits target-addressed commands
  across two spellings — the same split that made `sol cloud` worth removing.
- **Making listings take the target positionally** (`sol releases <target>`). Rejected:
  it would make one family two shapes — `sol secret set <key> --target <t>` alongside
  `sol secret list <target>` — and "the positional is the instance the verb acts on" is
  worth more than matching `sol plan`'s shape by eye.
- **A `view` axis** (an "operational concern" flag). Already settled the other way: the
  view is a subcommand of `sol open`.
- **An `--env` flag or an ambient current target.** Rejected by `DEC-016`.

## 4. The intended tree

```
sol
  # lifecycle: the target is the subject
  plan        <target>                            preview the whole target (read-only)
  deploy      <target>                            reconcile the whole target
  destroy     <target>                            reconcile the target toward empty
  uninstall   <target>                            remove the durable installation
  export      <target>                            non-destructive emit            (#1307)
  detach      <target>                            one-way ownership handoff       (#1307)
  up                                              build + deploy to the local cluster

  # the target's own report: the target is the subject
  show        <target> [--check] [--json] [-v]    resolved target + live readiness
  reconcile   <target> [--explain]                recorded vs observed ownership

  # scope-addressed: the scope is the subject, --target qualifies
  status      [<scope>] [--target <target>]       workspace/domain/service health
  logs        <unit>    [--target <target>]       stream a workload's logs
  check       [<scope>]                           validate declarations
  open        dashboard|logs|metrics|traces [<scope>] [--target <target>]
  open        infra     --target <target>         (no scope: infrastructure has none)

  # listings: no instance; the target selects
  releases    [--target <target>]                 the release records the cluster holds
  deployments [--target <target>]                 the deployment events the cluster holds
  secret      list [--domain <d>] [--target <t>]  list secret keys

  # workspace verbs
  rollback    <release-id> [--scope <s>] [--target <t>]
  alert       test  [--target <target>]
  fn          run   <domain/name> [--target <target>]
  assets

  # families
  new         workspace|svc|worker|fn|event <name/…>
  secret      set|delete <key> [--domain <d>] [--target <t>]
  migrate     apply <target>
  migrate     rollback|status
  grants      plan|apply <target>
  ci          init <provider>
  contract    generate [--check]
  local       …                                   no target exists here
```

## 5. Diff against the current CLI

The current surface is 50 commands (`sol <command> --help=plain`), classified by
`internal/ci/lib/cli_surface.py`. Against § 4:

### Work — the diff

| # | current | intended | why |
|---|---|---|---|
| 1 | `sol target show --target <t>` | `sol show <target>` | the target is the subject: the command names one target. Drops the `sol target` group. |
| 2 | `sol target reconcile <target>` | `sol reconcile <target>` | same rule; rename only (already positional). |
| 3 | `sol logs --scope <unit> --target <t>` | `sol logs <unit> --target <t>` | the unit **is** the subject; `--scope` hides it behind a flag. |
| 4 | `sol check --scope <scope>` | `sol check [<scope>]` | same rule: the scope is the subject, and omitting it means the workspace. |

Items 1–2 delete the `sol target` group, so `cli/bin/cmd_target.ml`'s group goes away and
its two commands become top-level modules.

### Matches — done

| command | why it matches |
|---|---|
| `sol plan`, `sol deploy`, `sol destroy`, `sol uninstall` | target positional; the lifecycle spine |
| `sol grants plan`, `sol grants apply`, `sol migrate apply` | target positional |
| `sol status`, `sol open dashboard\|logs\|metrics\|traces` | scope positional, `--target` qualifies |
| `sol open infra` | `--target` only; a scope is refused, not ignored |
| `sol releases`, `sol deployments`, `sol secret list` | listings: no instance, `--target` selects |
| `sol secret set\|delete` | key positional, `--target`/`--domain` qualify |
| `sol rollback` | release-id positional; `--scope`/`--target` qualify |
| `sol fn run`, `sol alert test` | no target-shaped instance; `--target` qualifies |
| `sol up` | local; `--scope` narrows, no target |
| `sol new …`, `sol ci init`, `sol contract generate`, `sol assets` | workspace verbs/families |
| `sol local …` | the local family |

### Open questions this page does not settle

Named rather than silently passed; each needs a product call before it is work.

- **`sol migrate apply <target>` vs `sol migrate rollback|status`.** Apply is
  target-addressed; rollback and status take `--dir`/`--table` and no target. If all three
  act on a target's database, the model says all three take `<target>` positionally; if
  rollback and status act on a local file, they are workspace verbs and the asymmetry is
  correct. Decide which they are.
- **`sol fn run` and `sol migrate` name a subject with a slash** (`domain/name`) that the
  scope grammar also produces. It is a workload identity here, not a scope; the two must
  not be conflated if `--scope` and that positional ever coexist on one command.
- **The verb for `sol show`.** `show` is short and verb-shaped like `sol plan`/`sol status`;
  `inspect` or `target show` are the alternatives. It is a name, not a model question.

## 6. Keeping this honest

- The **current** surface is generated and guarded: `docs/reference/cli.md` is rendered
  from the binary by `render-cli-reference.py`, and `check_cli_reference.py` fails CI when
  they disagree. This page is the **target**, so it is not generated; it is reviewed like
  any other decision.
- When an item in § 5 lands, move the row out of *Work* and regenerate
  `docs/reference/cli.md`.
- One rule is enough for a new command: find the instance the verb acts on, put it in the
  positional, and put the target in `--target` unless the target *is* that instance. If the
  verb names no instance, there is no positional and the target is `--target`.
