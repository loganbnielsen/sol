# FND-0023 — the deploy identity cannot maintain three Sol-owned mutable ConfigMaps, for one reason

**Classification:** `VERIFIED_DEFECT` · **State:** `OPEN`
**Severity:** high · **Ticket:** `INFRA-063` · **Evidence:** `BEHAVIORAL` + `STATIC`
**Found while:** Run 8 §B, across three separate operations

## The pattern

Three distinct Sol-owned, mutable ConfigMaps in `default` are written with an
operation that becomes a **patch** when the object already exists, and the deploy
identity holds only `get`/`list`/`watch`/`create`/`update` there — never `patch`:

| Object | What it carries | Effect when it cannot be written |
|---|---|---|
| `sol-release-current-<workspace>` | the release pointer | the deploy used to report success anyway (**FND-0014**, fixed by `get`+`create`/`replace`) |
| release records | the release history | pruning cannot run (`INFRA-051`) |
| `sol-deploy-state-<workspace>` | consumer-group drift state | **BUG-025's drift check has no state to compare against** |

The third was observed live during the fixture-reset attempt:

```
warning: could not record deploy state (sol-deploy-state-pluto): … cannot patch
resource "configmaps" in API group "" in the namespace "default"
```

## Why it is one finding and not four tickets

The first instance was fixed by changing the *object's* write mechanism (`get`, then
`create` when absent or `replace` when present — no generic `patch` needed). The
remaining instances are the same mismatch on the same object class, written by the same
identity, authorised by the same grant. Fixing a fourth object name individually would
leave the class broken and guarantee a fifth.

**The class is: every Sol-owned mutable ConfigMap written by the deploy identity.**

## The important consequence

BUG-025's drift protection is currently **unable to observe anything**: its state
object cannot exist. A check that cannot obtain its input is exactly the failure shape
this run keeps finding — and it means BUG-025 must not be qualified as working until
the state it reads can actually be maintained.

## What would make it qualified

An audit of every mutable Sol-owned ConfigMap the deploy identity writes, each using
the established narrow mechanism (`get` → `create`/`replace`, never a generic `patch`),
with coverage that a second write of an existing object succeeds — and, for the drift
state specifically, evidence that BUG-025 observes a real change rather than an absent
object.
