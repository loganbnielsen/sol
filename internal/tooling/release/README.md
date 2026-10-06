# Releasing Sol

A Sol release is two stages: an immutable **candidate** built from one tagged
revision, and a **promotion** that publishes that exact candidate only after the
authorized cloud qualification refers to it. Nothing publishes from a tag.

## 1. Candidate (automated)

`.github/workflows/release.yml` runs on a `v*` tag (and on `workflow_dispatch`
to resume an interrupted build). It refuses a branch and a checkout that is not
the tag's commit, then builds from that revision:

- the release binary, stamped with `SOL_RELEASE_VERSION`;
- the platform bundle;
- the version-aligned migration-runner image, published once and reused by
  digest on a resume;
- `candidate.json`, the candidate identity.

It records the candidate as a **draft** GitHub release with the bundle and
`candidate.json` attached, runs `internal/ci/smoke_installed_release.sh`, and
stops. A re-run of the same tag only succeeds when the recorded candidate
matches the rebuild, so the candidate cannot move underneath a qualification run.
A published version is never rebuilt.

The migration-runner image is pushed by the candidate build because qualification
installs the candidate by the digest the bundle records; the image is immutable
and reused by digest on a resume. What promotion gates is the user-facing
release: the bundle and the release page.

`candidate.json` is the identity qualification and promotion must agree on:

```json
{
  "version": "v0.1.0-alpha.9",
  "revision": "<40-hex commit>",
  "bundle": "sol-v0.1.0-alpha.9-linux-x86_64.tar.gz",
  "bundle_sha256": "<64-hex>",
  "runner_image": "ghcr.io/<owner>/sol-migration-runner@sha256:<64-hex>"
}
```

## 2. Qualification (operator-authorized, live)

Qualification is the live AWS and GCP campaign in
[`internal/qualification/`](../../qualification/README.md). It is **not**
automated by the release workflow: it provisions billable infrastructure and
performs destructive lifecycle actions, so an operator authorizes it
explicitly. Run it against the installed candidate — extract the draft's bundle
and set `SOL_INSTALL` to its `sol-<version>` prefix — and follow the provider's
procedure (`aws/aws-run-procedure.md`, `gcp/gcp-production-single-region-v1-matrix.md`).

The campaign produces one verdict document, `qualification-verdict.json`, whose
`candidate` block is the candidate identity above:

```json
{
  "candidate": {
    "version": "v0.1.0-alpha.9",
    "revision": "<40-hex commit>",
    "bundle_sha256": "<64-hex>",
    "runner_image": "ghcr.io/<owner>/sol-migration-runner@sha256:<64-hex>"
  },
  "providers": {
    "aws": {
      "verdict": "pass",
      "required_rows": ["B1", "I8"],
      "rows": [
        {"id": "B1", "status": "pass", "evidence": "..."},
        {"id": "I8", "status": "pass", "evidence": "..."}
      ],
      "teardown": {"absence_verdict": "pass", "evidence": "aws-inventory-verdict.txt"}
    },
    "gcp": {
      "verdict": "pass",
      "required_rows": ["B1"],
      "rows": [{"id": "B1", "status": "pass", "evidence": "..."}],
      "teardown": {"absence_verdict": "pass", "evidence": "gcp-inventory-verdict.txt"}
    }
  }
}
```

Row status is `pass`, `fail`, `blocked`, `not_run` or `excluded`. Every
`required_rows` id must appear with `status: pass`; `blocked`, `not_run` and
`excluded` rows stay in the record with a reason and never become a pass through
omission. `teardown.absence_verdict` is the independent post-destroy absence
result — Sol's exit code and Terraform state are not absence evidence.

## 3. Promotion (automated gate, operator-triggered)

`.github/workflows/promote.yml` never builds. It downloads the draft candidate
and the verdict attached to it, runs
`python3 internal/tooling/release/promotion.py decide`, and only then flips the
draft to published with `gh release edit --draft=false`. The published bundle is
byte-for-byte the candidate that was qualified.

The decision refuses when the verdict is missing, malformed, for another
candidate, missing a required provider, or has a failing/omitted/blocked
release-blocking row or no independent absence result. Its mechanics are pinned
by `internal/ci/test_candidate_promotion.py`; those tests establish the decision
only and are not qualification evidence.

### Exact operator action

1. Run the authorized AWS and GCP campaign against the installed candidate and
   write the verdict's `candidate` block from the draft's `candidate.json`.
2. Attach the verdict to the draft candidate:
   `gh release upload <version> qualification-verdict.json`.
3. Run **Promote release** with `version=<version>`.

Until step 3, the version is a draft and nothing a user installs can name it.
