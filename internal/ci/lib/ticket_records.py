import re

import yaml

ID = re.compile(r"^([A-Z]+-[0-9]+)\.md$")
STATES = ("BACKLOG", "READY_FOR_ENGINEERING", "DONE")
ROOTS = ("internal/pipeline/tickets", "pipeline/tickets")


def ticket_of(path):
    for root in ROOTS:
        prefix = root + "/"
        if not path.startswith(prefix):
            continue
        rest = path[len(prefix) :]
        state, _, name = rest.partition("/")
        if state not in STATES or "/" in name:
            return None
        match = ID.match(name)
        if not match:
            return None
        return root, state, match.group(1), name
    return None


def frontmatter(text):
    parts = text.split("---")
    if len(parts) < 3 or parts[0].strip():
        return {}
    try:
        parsed = yaml.safe_load(parts[1])
    except yaml.YAMLError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def rename_problems(change, exists_at_base):
    destination = ticket_of(change["destination"])
    if destination and exists_at_base(change["destination"]):
        _root, _state, ticket_id, _name = destination
        return [
            f"moving {change['source']} onto {change['destination']} would replace the "
            f"{ticket_id} record already there: take the next free id, or edit that record in "
            f"place if this is the same ticket"
        ]
    return []


def addition_problems(change, occupied_by, moved_ids=()):
    added = ticket_of(change["path"])
    if added:
        _root, _state, ticket_id, _name = added
        if ticket_id in moved_ids:
            return []
        occupied = occupied_by(ticket_id)
        if occupied:
            return [
                f"adding {change['path']} reuses {ticket_id}, which already exists at "
                f"{occupied}: two actors allocated the same id, so one record would replace "
                f"the other. Take the next free id instead"
            ]
    return []


def modification_problems(change, base_text, head_text, subjects):
    ticket = ticket_of(change["path"])
    if not ticket:
        return []
    _root, state, ticket_id, _name = ticket
    if state != "DONE":
        return []
    if any("(title correction)" in subject for subject in subjects):
        return []
    before = frontmatter(base_text).get("title")
    after = frontmatter(head_text).get("title")
    if before and after and before != after:
        return [
            f"{change['path']} changes a finished record's title, which is how a different "
            f"record replaces this one silently ({ticket_id}):\n"
            f"      was: {before}\n"
            f"      now: {after}\n"
            f"    A different defect needs a different id. If this is a correction to the "
            f"same record, say so with '(title correction)' in a commit subject."
        ]
    return []
