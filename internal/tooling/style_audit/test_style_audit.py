import json
import pathlib
import subprocess
import sys
import tempfile

binary = pathlib.Path(sys.argv[1]).resolve()


def run(*paths, json_output=True, cwd=None):
    args = [str(binary)]
    if json_output:
        args.append("--json")
    return subprocess.run(args + [str(path) for path in paths], capture_output=True, text=True, cwd=cwd)


with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    source = root / "sample.ml"
    source.write_text(
        """let consume
    ~sw ~net ~clock ~handler
    ?(on_ready = ignore)
    ?(on_poll = Stdlib.ignore)
    ?(on_retry = fun _ -> ())
    ?(on_error = fun _ -> print_endline "failure")
    () = ()
let render ~workspace ~environment ~release_id ~target () = ()
let twelve a b c d e f g h i j k l = ()
let eleven a b c d e f g h i j k = ()
let client ~http_host ~http_port ~http_scheme ~http_path () = ()
let fewer ~http_host ~http_port ~http_scheme () = ()
let two ~on_ready ~on_poll () = ()
let renamed ~on_ready:ready ~on_poll:poll ~on_retry:retry () = ()
let text = "let fake ~on_a ~on_b ~on_c () = ()"
(* let hidden ~on_a ~on_b ~on_c () = () *)
let nested () =
  let local ~on_a ~on_b ~on_c () = () in local
let typed : _ = fun ~on_a ~on_b ~on_c () -> ()
let polymorphic (type a) ~on_a ~on_b ~on_c (x : a) = x
let cases ~on_a ~on_b ~on_c = function _ -> ()
let returned ~on_a = fun ~on_b -> fun ~on_c -> ()
"""
    )
    interface = root / "sample.mli"
    interface.write_text(
        "val consume : ?on_ready:(unit -> unit) -> ?on_poll:(unit -> unit) -> "
        "?on_retry:(unit -> unit) -> ?on_error:(unit -> unit) -> unit -> unit\n"
        "val client : http_host:string -> http_port:int -> http_scheme:string -> "
        "http_path:string -> unit -> unit\n"
    )
    for excluded in ["_build", "_opam", ".git", "node_modules", "vendor"]:
        folder = root / excluded
        folder.mkdir()
        (folder / "ignored.ml").write_text("let broken =")
    (root / "cycle").symlink_to(root, target_is_directory=True)
    result = run(root)
    assert result.returncode == 0, result.stderr
    findings = json.loads(result.stdout)
    by_key = {(item["file"], item["function"], item["rule"]): item for item in findings}
    consume = by_key[(str(source), "consume", "parameter-sprawl")]
    assert (consume["line"], consume["column"]) == (1, 5), consume
    assert (consume["parameters"], consume["optional"], consume["defaulted"], consume["noop_defaults"]) == (9, 4, 4, 3), consume
    family = by_key[(str(source), "consume", "parameter-family")]
    assert family["family"] == ["on_ready", "on_poll", "on_retry", "on_error"], family
    assert by_key[(str(source), "twelve", "parameter-sprawl")]["parameters"] == 12
    assert by_key[(str(source), "polymorphic", "parameter-family")]["parameters"] == 4
    assert by_key[(str(source), "cases", "parameter-family")]["parameters"] == 4
    assert by_key[(str(source), "returned", "parameter-family")]["parameters"] == 3
    assert by_key[(str(interface), "consume", "parameter-sprawl")]["defaulted"] == 0
    assert by_key[(str(interface), "client", "parameter-family")]["family"] == ["http_host", "http_port", "http_scheme", "http_path"]
    assert {item["function"] for item in findings} == {"consume", "twelve", "client", "local", "typed", "polymorphic", "cases", "returned", "renamed"}, findings
    assert run(source, source).stdout == run(source).stdout
    assert by_key[(str(interface), "consume", "parameter-sprawl")]["parameters"] == 5
    assert by_key[(str(source), "renamed", "parameter-family")]["family"] == ["on_ready", "on_poll", "on_retry"]
    default = run(cwd=root)
    assert default.returncode == 0 and len(json.loads(default.stdout)) == len(findings)
    text = run(source, json_output=False)
    assert text.returncode == 0 and f"{source}:1:5: [parameter-family] consume:" in text.stdout
    clean = root / "clean.ml"
    clean.write_text("let identity x = x\n")
    assert json.loads(run(clean).stdout) == []
    broken = root / "broken.ml"
    broken.write_text("let broken =\n")
    partial = run(broken, source)
    assert partial.returncode == 1 and str(broken) in partial.stderr, partial
    assert json.loads(partial.stdout), partial.stdout
    missing = run(root / "missing.ml")
    assert missing.returncode == 1 and "missing.ml" in missing.stderr, missing
    assert run("--unknown-option").returncode != 0

print("style_audit: AST families, thresholds, defaults, signatures, traversal and errors passed")
