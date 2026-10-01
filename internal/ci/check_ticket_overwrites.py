import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent / "lib"))

import ticket_records


def repository():
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True
    )
    root = result.stdout.strip()
    return Path(root) if result.returncode == 0 and root else HERE.parents[1]


def git(*args, check=True):
    result = subprocess.run(
        ["git", *args], cwd=repository(), capture_output=True, text=True
    )
    if check and result.returncode != 0:
        raise SystemExit(
            f"check_ticket_overwrites: git {' '.join(args)} failed: {result.stderr.strip()}"
        )
    return result.stdout


def exists_at_base(base, path):
    return (
        subprocess.run(
            ["git", "cat-file", "-e", f"{base}:{path}"], cwd=repository(), capture_output=True
        ).returncode
        == 0
    )


def file_at(ref, path):
    return git("show", f"{ref}:{path}", check=False)


def occupied_by(base, ticket_id):
    for root in ticket_records.ROOTS:
        for state in ticket_records.STATES:
            path = f"{root}/{state}/{ticket_id}.md"
            if exists_at_base(base, path):
                return path
    return None


def changes(base):
    found = []
    for line in git("diff", "--name-status", "-M", f"{base}...HEAD").splitlines():
        fields = line.split("\t")
        kind = fields[0][:1]
        if kind == "R" and len(fields) == 3:
            found.append({"kind": "R", "source": fields[1], "destination": fields[2]})
        elif kind in ("A", "M", "D") and len(fields) == 2:
            found.append({"kind": kind, "path": fields[1]})
    return found


def moved_ids(changes):
    ids = set()
    for change in changes:
        if change["kind"] != "D":
            continue
        ticket = ticket_records.ticket_of(change["path"])
        if ticket:
            ids.add(ticket[2])
    return ids


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Refuse a change that would replace a ticket record: a move onto an existing "
            "record, a new ticket reusing a taken id, or a finished record's title changing."
        )
    )
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()

    base = args.base
    subjects = git("log", "--format=%s", f"{base}..HEAD").splitlines()
    found = changes(base)
    moved = moved_ids(found)
    problems = []
    for change in found:
        if change["kind"] == "R":
            problems += ticket_records.rename_problems(change, lambda p: exists_at_base(base, p))
        elif change["kind"] == "A":
            problems += ticket_records.addition_problems(
                change, lambda ticket_id: occupied_by(base, ticket_id), moved
            )
        elif change["kind"] == "M":
            path = change["path"]
            problems += ticket_records.modification_problems(
                change, file_at(base, path), file_at("HEAD", path), subjects
            )

    if problems:
        print(
            "check_ticket_overwrites: this change would replace a ticket record rather than "
            "move or edit one:",
            file=sys.stderr,
        )
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "  Ticket ids are allocated by whoever needs one, so two actors can pick the same "
            "number concurrently; the tree keeps one record per id, and these checks are what "
            "stops the second from deleting the first.",
            file=sys.stderr,
        )
        return 1

    print(
        f"check_ticket_overwrites: no ticket record is replaced by this change "
        f"({len(found)} ticket-tree change(s) checked)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
