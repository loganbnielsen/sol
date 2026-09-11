---
id: FEAT-062
type: feature
severity: low
source: FEAT-059 review, 2026-09-11 — inspectable is not the same as authorable
---

**Depends on:** FEAT-059.

Show a target as a target — provider, region, cluster, and whether Kubernetes is reachable — rather than as kubectl output.

**Related:** DEC-020, DEC-019.

## Problem

FEAT-059 stores the Kubernetes destination in the target so that deploys are deterministic. The risk it introduces is that **the config becomes the user-facing API by default**: the easiest way to answer "where will this deploy go?" becomes reading `sol/<env>/<provider>/<region>.yml` and knowing which fields matter.

Today there is no way to ask a product question — *what am I about to deploy to?* — without reading configuration. Three consequences:

- Users have to learn the config schema to answer a question the product should answer.
- The raw context string (frequently an ARN) becomes the thing people copy and share, which is how an implementation mechanism turns into an expected interface. FEAT-059 explicitly must not end up there.
- There is no way to tell **"configured"** from **"reachable"**. A target can name a context that no longer exists, and nothing says so until a deploy fails.

## Proposed behaviour

```
sol target show <target>

  Target      prod
  Provider    aws
  Region      us-west-2
  Cluster     sol-prod
  Registry    <account>.dkr.ecr.us-west-2.amazonaws.com
  Kubernetes  reachable
```

- **The raw context is never in the default output.** It appears only with an explicit `--verbose`/`--raw`, for the person debugging the plumbing rather than the person deploying.
- **Configured-but-unreachable is distinct from not-configured.** Three states, named: not configured, configured but unreachable, reachable. This is the same distinction the rest of this work insists on — "could not verify" must never read as "fine".
- **`--json`** for scripting, since the platform (DEC-019) will want a stable machine-readable answer to the same question.

## The one decision to make

Does the default check reachability, or only report what is configured?

- **Offline by default, `--check` for reachability** keeps `show` fast, credential-free and useful in CI or a fresh checkout, at the cost of the reachability line being opt-in.
- **Reachability by default** matches the example above, but makes an inspection command need cluster credentials and network access.

The recommendation is offline by default with `--check`, and a `Kubernetes  configured (not checked)` line — because an inspection command that fails without credentials is a worse trade than one that needs a flag to probe.

## Acceptance criteria

- `sol target show <target>` answers "where would this deploy go?" without the user reading configuration.
- The default output distinguishes not-configured from configured-but-unreachable.
- The raw context appears only with an explicit flag.
- `--json` emits a stable, documented shape.
- Naming an unknown target fails closed, listing what is available.
- The default does not require cluster credentials (or the decision above is resolved the other way, deliberately, and documented).

## Notes

Not a prerequisite for FEAT-059 — destinations can land without a way to display them. It is the ergonomics companion, and it should follow soon after, while the destination is fresh: the longer the only way to see a destination is to read YAML, the more the YAML is the interface.
