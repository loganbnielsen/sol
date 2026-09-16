---
id: RELEASE-005
type: release
severity: high
source: DEC-025 (2026-09-16) — publication work split out as release engineering so it does not block FEAT-085
---

Publish the Sol OCaml framework, and the dependencies it needs, to the public
opam-repository.

**Depends on:** INFRA-007's opam half (licence and dependency inventory of the
opam graph — still not inventoried; distribution is what triggers the
obligations, so this gates publication).

**Related:** DEC-025, DEC-013, FEAT-085, INFRA-007.

**Problem:** DEC-025 chose opam as the canonical distribution mechanism for the
Sol OCaml framework, and accepted immutable git opam pins (tag or commit) as the
interim so FEAT-085 is not blocked. The interim is explicitly *not* a
distribution story:

- Consumers need network and git access to six repositories at build time.
- The framework has no ecosystem home, so it is not discoverable or installable
  the way every other Sol OCaml dependency already is.
- The pin list is private infrastructure knowledge that has to be copied into
  every generated Dockerfile, which is what the generated template does today.

Measured against `ocaml/opam-repository` on 2026-09-16:

| Package | Public opam-repository |
| --- | --- |
| `kafka-eio`, `obs-eio`, `obs-prometheus-eio`, `https-eio`, `aws-eio` | published |
| `obs-loki-eio`, `obs-tempo-eio`, `pg-eio`, `lambda-eio`, `s3-eio`, `dynamodb-eio` | **not published** |
| `sol-svc`, `sol-worker`, `sol-fn`, `sol-jobs`, `sol-obs`, `kafka-eio-service` | **not published** |

Four of the unpublished dependencies are needed by the framework itself:
`sol-obs` needs `obs-loki-eio` and `obs-tempo-eio`; `sol-jobs` needs `pg-eio`;
`sol-fn` needs `lambda-eio`. So the framework cannot be published before them.

Two of them also have **no tags at all**, which is why the interim has to
commit-pin rather than tag-pin them:

```text
obs-tempo-eio   no tags
lambda-eio      no tags
```

**Goal:** every framework package installable by name from the public
opam-repository, so a workspace declares them in its own opam metadata the way it
declares any other dependency, with no pins and no `$SOL_HOME`.

**Remediation:**

1. **Discharge INFRA-007's opam inventory first** — licence and dependency graph
   of everything the framework would ship and depend on. This is the same gate
   DEC-023/INFRA-007 applied before publishing to npm; it is currently unmet.
2. **Cut immutable releases for `obs-tempo-eio` and `lambda-eio`**, which have
   no tags. Until then they can only be commit-pinned, which DEC-025 permits but
   which no consumer can reasonably be asked to do.
3. **Submit the six unpublished `*-eio` dependencies** to
   `ocaml/opam-repository`, in dependency order.
4. **Submit the six framework packages** — `sol-svc`, `sol-worker`, `sol-fn`,
   `sol-jobs`, `sol-obs`, `kafka-eio-service` — as a **coordinated release
   train** (DEC-025: public library boundaries do not imply independent
   versioning). `sol-runtime` and `sol-env` stay unpublished implementation
   detail.
5. **Replace the interim pins.** Once the packages are installable by name:
   - `sol new workspace` declares ordinary framework dependencies instead of
     emitting git pins;
   - `sol up` and the generated Dockerfile drop the `opam pin add …#main` block
     entirely — that block is exactly the mutable-branch pin DEC-025 forbids;
   - the README/scaffold language moves from "pin these six repositories" to
     "declare these packages".
6. **Record the coordinated version string** and how framework, CLI and `*-eio`
   versions are asserted compatible at release time — DEC-013 raised "a version
   story" and it is still unanswered.

**Acceptance criteria:**

- All six framework packages install by name from the public opam-repository with
  no pins, on a clean switch.
- The four blocking `*-eio` dependencies are published, and `obs-tempo-eio` and
  `lambda-eio` carry immutable releases.
- No generated workspace or Dockerfile contains an `opam pin` for a Sol or
  `*-eio` package, and none references a mutable branch.
- A freshly scaffolded workspace builds with no `$SOL_HOME`, satisfying all three
  DEC-025 invariants (location, installation, version) without the interim pins —
  i.e. this ticket's completion is provable by the same `/tmp/foo` test FEAT-085
  uses, run with no pins configured.
- INFRA-007's opam dependency/licence inventory is recorded in
  `docs/legal/third-party-licenses.md` alongside the npm inventory.
