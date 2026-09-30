import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

AXES = ("target", "scope", "workspace", "local")

MARKER_BEGIN = "<!-- BEGIN GENERATED: {axis} -->"
MARKER_END = "<!-- END GENERATED: {axis} -->"

SECTION_HEADERS = re.compile(r"^([A-Z][A-Z ]+)$", re.M)


@dataclass
class Command:
    path: str
    purpose: str
    positional: str
    flags: list = field(default_factory=list)
    documents_exit: bool = False
    axis: str = "workspace"


def plain_help(binary, args):
    result = subprocess.run(
        [binary, *args, "--help=plain"], capture_output=True, text=True
    )
    return result.stdout + result.stderr


def sections(text):
    parts = SECTION_HEADERS.split(text)
    found = {}
    for index in range(1, len(parts) - 1, 2):
        found[parts[index].strip()] = parts[index + 1]
    return found


def indented_entries(block):
    return [
        line.strip() for line in block.splitlines() if re.match(r"^ {7}\S", line)
    ]


def first_token(entry):
    return entry.split()[0]


def command_names(block):
    found = []
    for entry in indented_entries(block):
        name = first_token(entry)
        if re.match(r"^[a-z][a-z0-9-]*$", name):
            found.append(name)
    return found


def purpose_of(block):
    for line in block.splitlines():
        stripped = line.strip()
        if " - " in stripped:
            purpose = stripped.split(" - ", 1)[1]
            return " ".join(purpose.split())
    return ""


def positional_of(entries):
    names = [first_token(entry) for entry in entries]
    names = [name for name in names if re.match(r"^[A-Z][A-Z_/\[\]]*$", name)]
    return ", ".join(names)


def flags_of(entries):
    found = []
    for entry in entries:
        token = first_token(entry)
        for piece in token.split(","):
            piece = piece.strip()
            if piece.startswith("--") or (piece.startswith("-") and len(piece) == 2):
                found.append(piece)
    return found


def classify(path, positional, flags):
    if path.startswith("sol local"):
        return "local"
    names = [name.strip() for name in positional.split(",") if name.strip()]
    if "TARGET" in names:
        return "target"
    if "SCOPE" in names:
        return "scope"
    if not names and any(flag.startswith("--target") for flag in flags):
        return "target"
    if not names and any(flag.startswith("--scope") for flag in flags):
        return "scope"
    return "workspace"


def walk(binary, path=("sol",)):
    text = plain_help(binary, list(path[1:]))
    found = sections(text)
    if "COMMANDS" in found:
        for name in command_names(found["COMMANDS"]):
            yield from walk(binary, path + (name,))
        return
    positional = positional_of(indented_entries(found.get("ARGUMENTS", "")))
    flags = flags_of(indented_entries(found.get("OPTIONS", "")))
    command_path = " ".join(path)
    yield Command(
        path=command_path,
        purpose=purpose_of(found.get("NAME", "")),
        positional=positional,
        flags=flags,
        documents_exit="EXIT STATUS" in found,
        axis=classify(command_path, positional, flags),
    )


def registered(binary):
    commands = list(walk(binary))
    commands.sort(key=lambda command: command.path)
    return commands


def escape(text):
    return text.replace("|", "\\|").replace("\n", " ").strip()


def render_axis(commands):
    lines = [
        "| command | positional | flags | exit | purpose |",
        "|---|---|---|---|---|",
    ]
    for command in commands:
        positional = escape(command.positional) if command.positional else "—"
        flags = ", ".join(f"`{escape(flag)}`" for flag in command.flags) or "—"
        exit_note = "documented" if command.documents_exit else "—"
        lines.append(
            "| `{}` | {} | {} | {} | {} |".format(
                command.path, positional, flags, exit_note, escape(command.purpose)
            )
        )
    return "\n".join(lines)


def render_block(commands):
    grouped = {axis: [] for axis in AXES}
    for command in commands:
        grouped[command.axis].append(command)
    return {
        axis: render_axis(grouped[axis]) for axis in AXES if grouped[axis]
    }


def page_command_paths(text):
    found = set()
    for line in text.splitlines():
        match = re.match(r"^\| `(sol [^`]+)` \|", line)
        if match:
            found.add(match.group(1))
    return found


def normalize_flag(flag):
    return flag.split("=", 1)[0]


def claimed_flags(flags_cell):
    return {
        normalize_flag(flag)
        for flag in re.findall(r"`(--[^`=]+|-[a-zA-Z])(?:=[^`]*)?`", flags_cell)
    }


def page_flag_claims(text):
    claims = {}
    for line in text.splitlines():
        if not line.startswith("| `sol "):
            continue
        cells = line.split("|")
        if len(cells) < 5:
            continue
        command = cells[1].strip().strip("`")
        claims[command] = claimed_flags(cells[3])
    return claims


def replace_block(text, axis, body):
    begin = MARKER_BEGIN.format(axis=axis)
    end = MARKER_END.format(axis=axis)
    start = text.find(begin)
    if start < 0:
        raise ValueError(f"the page has no {begin} marker")
    stop = text.find(end, start)
    if stop < 0:
        raise ValueError(f"the page has no {end} marker")
    return text[: start + len(begin)] + "\n" + body + "\n" + text[stop:]


def rendered_page(page_text, commands):
    text = page_text
    for axis, body in render_block(commands).items():
        text = replace_block(text, axis, body)
    return text


def render_path(binary, page):
    page_path = Path(page)
    return rendered_page(page_path.read_text(), registered(binary))


def surface_drift(page_text, commands):
    documented = page_command_paths(page_text)
    expected = {command.path for command in commands}
    drift = []
    for path in sorted(expected - documented):
        drift.append(f"undocumented command: {path}")
    for path in sorted(documented - expected):
        drift.append(f"documented command the binary does not register: {path}")
    claims = page_flag_claims(page_text)
    real = {command.path: {normalize_flag(flag) for flag in command.flags} for command in commands}
    for path in sorted(set(claims) & set(real)):
        invented = claims[path] - real[path]
        if invented:
            drift.append(
                f"{path}: documented flags the command does not have: "
                + ", ".join(sorted(invented))
            )
    return drift
