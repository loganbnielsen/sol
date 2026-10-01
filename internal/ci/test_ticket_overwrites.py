import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "internal" / "ci" / "lib"))

import ticket_records

CHECK = ROOT / "internal" / "ci" / "check_ticket_overwrites.py"

TICKET = """---
id: {ticket_id}
type: bug
severity: medium
title: {title}
source: test
---

**Depends on:** None.

{body}
"""

failures = []


def ticket(ticket_id, title, body="A record with substance."):
    return TICKET.format(ticket_id=ticket_id, title=title, body=body)


def expect_problem(label, problems, needle):
    if not problems:
        print(f"  [FAIL] {label}: accepted", file=sys.stderr)
        failures.append(label)
        return
    if not any(needle in problem for problem in problems):
        print(f"  [FAIL] {label}: refused, but not for the reason under test", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        failures.append(label)
        return
    print(f"  [OK]   {label}")


def expect_accept(label, problems):
    if problems:
        print(f"  [FAIL] {label}: refused", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        failures.append(label)
        return
    print(f"  [OK]   {label}")


def pure_cases():
    rename = {
        "kind": "R",
        "source": "internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-108.md",
        "destination": "internal/pipeline/tickets/DONE/BUG-108.md",
    }
    expect_problem(
        "a move onto a record that is already there",
        ticket_records.rename_problems(rename, lambda path: True),
        "would replace the BUG-108 record",
    )
    expect_accept(
        "a move onto a free destination",
        ticket_records.rename_problems(rename, lambda path: False),
    )

    addition = {"kind": "A", "path": "internal/pipeline/tickets/DONE/BUG-108.md"}
    expect_problem(
        "a new ticket reusing a taken id",
        ticket_records.addition_problems(
            addition, lambda ticket_id: "internal/pipeline/tickets/DONE/BUG-108.md"
        ),
        "already exists at",
    )
    expect_accept(
        "a new ticket with a free id",
        ticket_records.addition_problems(addition, lambda ticket_id: None),
    )

    done = "internal/pipeline/tickets/DONE/BUG-108.md"
    change = {"kind": "M", "path": done}
    expect_problem(
        "a finished record replaced by a different one",
        ticket_records.modification_problems(
            change, ticket("BUG-108", "first defect"), ticket("BUG-108", "second defect"), []
        ),
        "A different defect needs a different id",
    )
    expect_accept(
        "the same change declared as a title correction",
        ticket_records.modification_problems(
            change,
            ticket("BUG-108", "first defect"),
            ticket("BUG-108", "second defect"),
            ["Fix the wording (title correction)"],
        ),
    )
    expect_accept(
        "an in-flight ticket reworded before it lands",
        ticket_records.modification_problems(
            {"kind": "M", "path": "internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-108.md"},
            ticket("BUG-108", "first defect"),
            ticket("BUG-108", "second defect"),
            [],
        ),
    )
    expect_accept(
        "a DONE ticket edited without touching its title",
        ticket_records.modification_problems(
            change,
            ticket("BUG-108", "one defect"),
            ticket("BUG-108", "one defect", "More evidence in the completion notes."),
            [],
        ),
    )
    expect_accept(
        "frontmatter that does not parse",
        ticket_records.modification_problems(change, "not a ticket\n", ticket("BUG-108", "x"), []),
    )


def end_to_end_case():
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        tickets = repo / "internal" / "pipeline" / "tickets"
        (tickets / "READY_FOR_ENGINEERING").mkdir(parents=True)
        (tickets / "DONE").mkdir(parents=True)
        (tickets / "DONE" / "BUG-108.md").write_text(ticket("BUG-108", "the first record"))

        def run(*args):
            return subprocess.run(
                ["git", *args], cwd=repo, capture_output=True, text=True, check=True
            )

        run("init", "-q", "-b", "main")
        run("config", "user.email", "test@example.invalid")
        run("config", "user.name", "test")
        run("add", "-A")
        run("commit", "-qm", "first")
        base = run("rev-parse", "HEAD").stdout.strip()

        (tickets / "READY_FOR_ENGINEERING" / "BUG-108.md").write_text(
            ticket("BUG-108", "a second record")
        )
        run("add", "-A")
        run("commit", "-qm", "a second ticket claims the same id")
        ready = tickets / "READY_FOR_ENGINEERING" / "BUG-108.md"
        (tickets / "DONE" / "BUG-108.md").write_text(ready.read_text())
        ready.unlink()
        run("add", "-A")
        run("commit", "-qm", "and lands it over the first record")

        result = subprocess.run(
            [sys.executable, str(CHECK), "--base", base],
            cwd=repo,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print("  [FAIL] the guard accepted a record replaced in place", file=sys.stderr)
            failures.append("end to end")
            return
        if "A different defect needs a different id" not in result.stderr:
            print(
                "  [FAIL] the guard refused the change, but not for the reason under test",
                file=sys.stderr,
            )
            print(result.stderr, file=sys.stderr)
            failures.append("end to end")
            return
        print("  [OK]   a real in-place replacement of a record is refused end to end")


pure_cases()
end_to_end_case()

if failures:
    print(f"test_ticket_overwrites: {len(failures)} case(s) went uncaught", file=sys.stderr)
    sys.exit(1)
print(
    "test_ticket_overwrites: the guard refuses a move onto an existing record, a reused id "
    "and a finished record's title changing, and allows the honest cases"
)
