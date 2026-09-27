import json
import sys
from pathlib import Path

FIXTURE = "cli/test/fixtures/terraform-output-gcp-cloud.json"


def fail(*lines):
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)


def fixture_problems(payload):
    problems = []
    if not isinstance(payload, dict) or not payload:
        return ["the fixture is not a non-empty object"]
    for name, entry in payload.items():
        if not isinstance(entry, dict):
            problems.append(f"{name} is not a terraform output record")
            continue
        if sorted(entry) != ["sensitive", "type", "value"]:
            problems.append(f"{name} carries {sorted(entry)}, not terraform's sensitive/type/value")
            continue
        if not isinstance(entry["value"], str) or not entry["value"].strip():
            problems.append(f"{name}'s value is not a non-blank string")
        if not isinstance(entry["type"], str):
            problems.append(f"{name}'s type is not a string")
        if not isinstance(entry["sensitive"], bool):
            problems.append(f"{name}'s sensitive flag is not a boolean")
    if "project_id" not in payload:
        problems.append("the fixture does not carry project_id")
    return problems


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    fixture = root / FIXTURE
    harness = root / "internal/ci/test_cloud_lifecycle_offline.sh"
    parser = root / "cli/lib/cloud/sol_cli_gcp_cluster.ml"
    for path in (fixture, harness, parser):
        if not path.is_file():
            fail(f"FAIL: missing {path}")
    try:
        payload = json.loads(fixture.read_text())
    except ValueError as e:
        fail(f"FAIL: the fixture is not JSON: {e}")
    problems = fixture_problems(payload)
    if problems:
        fail(*(f"FAIL: {p}" for p in problems))
    harness_text = harness.read_text()
    if FIXTURE not in harness_text:
        fail(
            "FAIL: the lifecycle harness does not serve the captured fixture, so its outputs payload is",
            "      a second, hand-written idea of terraform's shape (this is what hid FND-0063).",
        )
    harness_code = "\n".join(l for l in harness_text.splitlines() if not l.lstrip().startswith("#"))
    if '"project_id":{"value"' in harness_code:
        fail("FAIL: the invented single-field output shape is back in the lifecycle harness.")
    if "Sol_cli_cluster.outputs_reader" not in parser.read_text():
        fail(
            "FAIL: project_id_of_outputs_json does not read through Sol_cli_cluster.outputs_reader,",
            "      so Sol has a second, private idea of terraform's output shape.",
        )
    print("terraform output contract: the fixture carries terraform's fields, the harness renders it,")
    print("                          and the parser reads through Sol_cli_cluster.outputs_reader")


main()
