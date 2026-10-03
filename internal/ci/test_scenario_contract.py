import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci" / "check_scenario_contract.py"
CANONICAL = "examples/pluto/events/orders/sol.toml"
PROJECTION = "examples/pluto/events/demo_ts/sol.toml"


def run(checkout):
    environment = dict(os.environ)
    environment["SCENARIO_CONTRACT_CHECKOUT"] = str(checkout)
    return subprocess.run(
        [sys.executable, str(GUARD)], capture_output=True, text=True, env=environment
    )


def fail(message):
    print(f"  [FAIL] {message}")
    return 1


def main():
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="scenario-contract-"))
    try:
        shutil.copytree(ROOT / "examples", scratch / "examples")
        pristine = (scratch / PROJECTION).read_text()
        canonical_pristine = (scratch / CANONICAL).read_text()

        result = run(scratch)
        if result.returncode != 0:
            return fail(f"the guard must pass on an unmodified checkout:\n{result.stdout}{result.stderr}")
        print("  [OK]   the guard passes on the unmodified workspace")

        def mutate(relative, old, new, count=1):
            path = scratch / relative
            text = path.read_text()
            if text.count(old) != count:
                raise AssertionError(
                    f"the fixture changed: {relative} holds {text.count(old)} of {old!r}, expected {count}"
                )
            path.write_text(text.replace(old, new))

        def expect_failure(label, needle, relative, old, new, count=1):
            mutate(relative, old, new, count)
            result = run(scratch)
            (scratch / PROJECTION).write_text(pristine)
            (scratch / CANONICAL).write_text(canonical_pristine)
            if result.returncode == 0:
                return fail(f"the guard must fail when {label}")
            if needle not in result.stdout:
                return fail(f"the failure must name {needle} when {label}, got: {result.stdout}")
            print(f"  [OK]   the guard fails and names the file when {label}")
            return 0

        failures = 0
        schema = '    "quantity":       { "type": "integer" },'
        failures += expect_failure(
            "a projection event's schema drifts",
            PROJECTION,
            PROJECTION,
            schema,
            '    "quantity":       { "type": "string"  },',
            2,
        )
        failures += expect_failure(
            "a projection event's partition count drifts",
            PROJECTION,
            PROJECTION,
            "partitions = 3",
            "partitions = 6",
            2,
        )
        failures += expect_failure(
            "a projection event's key drifts",
            PROJECTION,
            PROJECTION,
            'key = "order_id"',
            'key = "item"',
            2,
        )
        failures += expect_failure(
            "a projection drops a canonical event",
            PROJECTION,
            PROJECTION,
            'name = "OrderFulfilled"',
            'name = "OrderFulfiled"',
        )
        failures += expect_failure(
            "a projection adds an event of its own",
            PROJECTION,
            PROJECTION,
            '[contract]\nlanguage = "typescript"',
            '[contract]\nlanguage = "typescript"\n\n[[events]]\nname = "Extra"\n'
            'topic = "sol-demo-ts-extra"\npartitions = 3\nkey = "order_id"\n'
            "schema = '{\"type\":\"object\",\"properties\":{\"order_id\":{\"type\":\"string\"}}}'",
        )
        failures += expect_failure(
            "a projection binds a topic the canonical scope already owns",
            CANONICAL,
            PROJECTION,
            'topic = "sol-demo-ts-orders"',
            'topic = "orders.v1"',
        )
        failures += expect_failure(
            "the canonical declaration changes under the projection",
            CANONICAL,
            CANONICAL,
            'key = "order_id"',
            'key = "item"',
            2,
        )

        (scratch / CANONICAL).write_text('[contract]\nlanguage = "ocaml"\n')
        result = run(scratch)
        (scratch / CANONICAL).write_text(canonical_pristine)
        if result.returncode == 0:
            failures += fail("the guard must fail when the canonical declaration has no events")
        elif CANONICAL not in result.stdout:
            failures += fail(
                "the empty-contract failure must name the canonical file, got: " + result.stdout
            )
        else:
            print(
                "  [OK]   the guard fails and names the file when the canonical declaration "
                "has no events"
            )
        return failures
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
