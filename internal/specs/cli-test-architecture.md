# Test architecture

Windtrap is Sol's only test framework. Every suite — the CLI inline tests and the
executable framework, lifecycle and fixture suites — uses it; no test links
Alcotest.

Ordinary CLI tests are discovered through Windtrap inline testing. A test lives
in a module of a library whose dune declares `(inline_tests)` and
`(preprocess (pps ppx_windtrap))`, and declares itself with `let%test`,
`module%test`, or `let%expect_test`. There is no list of test names to maintain:
adding a module to that library is the whole registration.

## Why

- Windtrap inline registration removes the shared `(tests (names ...))` registry.
  Every test-adding PR used to append to one hand-maintained list, so two such PRs
  always conflicted there; that class of conflict disappears.
- Dune builds one inline-test runner per module, so each module's tests share a
  process and separate modules never do. That is the isolation the previous
  one-executable-per-file layout had, so migrating a file into a library module
  preserves its process boundaries rather than weakening them. Dune's own
  limitation is real, though: there is no glob or `:standard` for `(tests (names
  ...))`, and `(include)` reads the source tree, so a generated registry is not
  available.
- The framework provides capabilities Sol already asks for, mutation testing
  first. `ppx_windtrap.mutate` and `windtrap coverage` can replace the manual
  edit/run/revert loop that every fix currently documents by hand.
- It is linked only by tests and has no third-party runtime dependencies beyond
  `unix`, so its churn cannot reach a shipped Sol artifact. It is pinned beside
  `yaml` in `sol.opam`, which is the file CI installs from, as a plain rather
  than a `{with-test}` dependency — a `{with-test}` pin would leave the library
  unbuildable in the jobs that build the default alias. It is young (0.1.0), which is accepted deliberately: a
  breakage stops CI, not production.

## Layout

- `cli/test/inline/` is the inline-test library (`sol_cli_inline_tests`). Modules
  here are ordinary tests; `cli_binary.ml` is the shared helper that locates the
  built `sol` binary.
- `cli/test/support/` is a helper library (`sol_cli_test_support`).
- `cli/test/dune` holds only the `(executable ...)` and `(test ...)` stanzas that
  must stay explicit executables; the legacy `(tests (names ...))` registry is
  gone.

## Reachability

`internal/ci/always/check_test_reachability.py` enforces that every module under
`cli/test/` is reachable: it is in a directory whose dune enables
`(inline_tests)`, in a directory holding a `(library ...)` stanza, or named by a
`(test ...)`, `(tests ...)`, `(executable ...)`, or `(executables ...)` stanza. A
module in none of those is compiled by nothing and run by nothing, which is how a
test disappears without a failure. The check reads dune files structurally and
keeps no manifest of its own; the legacy name list it consults is the one being
migrated away, and the scan root is a command-line argument so the guard's own
tests can point it at fixtures. `internal/ci/always/test_test_reachability.sh` exercises
both directions, including a test-bearing module in a plain directory.

## Retaining an executable

A test stays an explicit executable only when its executable or process
semantics are required:

- it needs its own `argv`;
- the test itself must be the process under test;
- it owns `Eio_main.run` or a comparable process-level lifecycle;
- the behaviour cannot be expressed faithfully under the inline-test runner.

Mutating `PATH`, the working directory, or environment variables is not a reason
to retain an executable: per-module process isolation already contains that.
The executable stanza and its test should make the required process boundary clear.
