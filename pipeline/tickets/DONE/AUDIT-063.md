---
id: AUDIT-063
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-063/route-path-parser
worktree: /home/lbendtly/Code/sun-AUDIT-063-route-path-parser
---

Replace ad hoc route path splitting with a URL-aware route matcher

**Depends on:** None.

**Description:** `framework/sun-svc/lib/route.ml` implements matching with:

```ocaml
String.split_on_char '/' path |> List.filter (fun s -> s <> "")
```

and parameter extraction with raw string segments. `Service.dispatch` separately rejects double slashes before calling the matcher. Path normalization, percent-encoding, empty segments, and parameter decoding are spread across simple string checks rather than a URL-aware path representation.

**Impact:** Routing behavior is hard to reason about for encoded path segments, empty path segments, trailing slash policy, and future wildcard/path-prefix features. The current matcher is small, but it is already coupled to extra validation in `Service.dispatch`, which makes entry points less clear.

**Remediation:**

1. Introduce a single path parsing/matching module that owns normalization, trailing slash policy, encoded segment handling, and parameter extraction.
2. Consider using a maintained router/path-pattern library if one fits the OCaml stack; otherwise keep the custom matcher but make its contract explicit and well-tested.
3. Move double-slash and path validation into the same module.
4. Add tests for percent-encoded segments, empty segments, trailing slash policy, duplicate parameter names, and malformed paths.

**Acceptance criteria:**

- Route matching has one clear implementation entry point.
- Encoded path behavior is documented and covered by tests.
- `Service.dispatch` no longer carries separate path-validation logic that belongs to routing.
- Existing routing and service tests continue to pass.

## Review — automated checks passed
Route path parsing consolidated into Route.parse_request_path and percent_decode; Service.dispatch delegates to Route; all 48 tests pass with no violations.
