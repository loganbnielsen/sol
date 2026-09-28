# Advisory OCaml parameter lint

Find parameter families and large signatures for human review. This tool parses
OCaml source with the installed compiler's `compiler-libs.common`; it does not
require a successful project build or type-check the files. Run it from Sol to
scan Sol or a support repository:

```bash
opam exec -- dune exec internal/tooling/style_audit/main.exe -- cli framework internal/tooling examples
opam exec -- dune exec internal/tooling/style_audit/main.exe -- ~/Code/kafka-eio
opam exec -- dune exec internal/tooling/style_audit/main.exe -- --json cli framework > candidates.json
```

With no paths, it scans the current directory. Multiple files/directories are
accepted. `.ml` implementations and `.mli` signatures are inspected, including
local bindings and bindings inside modules. Findings include file, line, column,
function name, rule, parameter counts and family members. Text is suitable for
editor navigation; JSON is an array of the same findings.

## Rules

- `parameter-family`: at least three labeled/optional arguments beginning with
  `on_`, or at least four sharing another prefix up to the first underscore,
  such as `http_host`, `http_port`, `http_scheme`, `http_path`.
- `parameter-sprawl`: at least 12 value parameters or four optional parameters.
  Includes counts of optional arguments, explicit defaults and syntactic no-op
  defaults (`ignore`, `Stdlib.ignore`, or a function whose body is `()`).

Positional arguments and trailing `()` count as value parameters. Locally
abstract type binders do not. A final `function` contributes one implicit
parameter. Curried function expressions are counted together. Interface arrows
are counted along the result spine, not inside callback argument types;
interfaces cannot report implementation defaults.

Warnings are candidate filters, not mandates to introduce records. Labeled
arguments may be independent and appropriate. `on_` names suggest callbacks but
are not proof of a function type; even `ignore` can be shadowed. The tool does
not infer conceptual cohesion, general callback types, aliases, or repeated
parameter families across sibling functions. It does not inspect anonymous
closures, object methods, generated PPX output or type signatures hidden behind
aliases. Implementation and interface locations are reported separately.

## Scan and exit behavior

Directory traversal skips hidden entries, `_build`, `_opam`, `node_modules`,
`vendor`, and symlinks. Explicit file roots are scanned even within excluded
folders; symlink roots are skipped. No source is changed and no tickets are
created. Findings exit 0. Invalid arguments, unreadable paths and syntax errors
exit nonzero, with errors on stderr; valid files can still produce findings.

Raw scaffold templates are not necessarily valid OCaml until rendered. The Sol
command above selects code directories to avoid parsing unrendered
`platform/shared/templates/` placeholders. To inspect templates, scan a generated
workspace. The parser must support the source's OCaml syntax; this implementation
uses OCaml 5.4's function AST.

## Verification

```bash
opam exec -- dune runtest internal/tooling/style_audit
```

The stdlib Python harness runs the executable against temporary source fixtures,
covering family/count thresholds, default shapes, nested bindings, interfaces,
comments/strings, directory exclusions, symlink cycles, JSON/text output and
parse/path failures. Its Dune `runtest` rule checks the tool; findings themselves
are advisory and are not a CI style gate.
