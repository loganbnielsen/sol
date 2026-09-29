# Windtrap inline-test prototype

A prototype of the registration model proposed for the CLI suite: a library with
`(inline_tests)` and `(preprocess (pps ppx_windtrap))`, whose modules declare
tests with `let%test`. Adding `cli/test/inline/<name>.ml` requires no edit to any
registration list, and `dune runtest` runs every declared test.

Measured on this branch:

- `dune build @cli/test/inline/runtest` runs the tests with no `(names ...)`
  anywhere; adding a module or a file is the whole change.
- Dune builds one inline-test runner per module, so each module's tests share a
  process and two modules never do. A cross-module environment leak passes; a
  same-module one fails, which is the same isolation the current one-file
  executables have.
- Filtering is `dune exec <runner> -- -f SUBSTRING` or `--tag`; `dune runtest`
  and `dune test cli/test` keep their meaning.
