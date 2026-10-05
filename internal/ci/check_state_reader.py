#!/usr/bin/env python3
import re
import sys
from pathlib import Path

NAME = "check_state_reader"
READER = "state_addresses"
RAW = ("state_list", "state_pull")
MLI = "cli/lib/cloud/sol_cli_terraform.mli"
IMPLEMENTATION = "cli/lib/cloud/sol_cli_terraform.ml"
STRUCTURAL = (Path(MLI).name, Path(IMPLEMENTATION).name)
RAW_REFERENCE = re.compile(r"\b(" + "|".join(RAW) + r")\b")


def exported_state_vals(path):
    text = path.read_text() if path.exists() else ""
    return set(re.findall(r"^val\s+(state_[a-z_]+)", text, re.M))


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(".")
    problems = []
    mli = root / MLI
    exported = exported_state_vals(mli)
    if READER not in exported:
        problems.append(
            f"{MLI} no longer exports {READER}, so the single Terraform state reader is gone"
        )
    for raw in RAW:
        if raw in exported:
            problems.append(
                f"{MLI} exports {raw} again: the raw listing must stay private to "
                f"{IMPLEMENTATION}, or a second state-reading path can repeat BUG-205's "
                "absent-versus-unreadable mix-up (BUG-210)"
            )
    for path in sorted((root / "cli").rglob("*.ml*")):
        if "_build" in path.parts or path.name in STRUCTURAL:
            continue
        text = path.read_text()
        for match in RAW_REFERENCE.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            problems.append(
                f"{path.relative_to(root)}:{line} reads the raw Terraform listing via "
                f"{match.group(1)}; use Sol_cli_terraform.{READER} so an absent state and an "
                "unreadable one stay distinct (BUG-210)"
            )
    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        return 1
    print(
        f"{NAME}: {MLI} exports {READER} and keeps the raw listing private; no module outside "
        f"{IMPLEMENTATION} reads it"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
