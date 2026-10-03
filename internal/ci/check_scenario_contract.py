import os
import pathlib
import sys

import tomli

CANONICAL = "examples/pluto/events/orders/sol.toml"
PROJECTIONS = ("examples/pluto/events/demo_ts/sol.toml",)

SEMANTIC_FIELDS = ("schema", "partitions", "key")


def scope_path(root, relative):
    return root / relative


def load_scope(root, relative, problems):
    path = scope_path(root, relative)
    if not path.is_file():
        problems.append(f"{relative} is missing")
        return None
    try:
        data = tomli.loads(path.read_text())
    except tomli.TOMLDecodeError as error:
        problems.append(f"{relative} is not valid TOML: {error}")
        return None
    language = data.get("contract", {})
    language = language.get("language") if isinstance(language, dict) else None
    if not isinstance(language, str) or not language:
        problems.append(f"{relative} declares no [contract] language")
    events = data.get("events", [])
    if not isinstance(events, list):
        problems.append(f"{relative} declares [[events]] that is not an array of tables")
        events = []
    by_name = {}
    topics = {}
    for entry in events:
        if not isinstance(entry, dict):
            problems.append(f"{relative} has an [[events]] entry that is not a table")
            continue
        name = entry.get("name")
        topic = entry.get("topic")
        if name in by_name:
            problems.append(f"{relative} declares the event {name!r} twice")
            continue
        if topic in topics:
            problems.append(
                f"{relative} declares the topic {topic!r} for both {topics.get(topic)!r} and {name!r}; "
                "two events in one scope cannot share a topic"
            )
        by_name[name] = entry
        topics[topic] = name
    return {"path": relative, "language": language, "events": by_name, "topics": topics}


def compare(canonical, projection, problems):
    where = projection["path"]
    if projection["language"] == canonical["language"]:
        problems.append(
            f"{where} binds the same language ({projection['language']!r}) as the canonical "
            f"declaration {CANONICAL}; a projection is a different language binding"
        )
    canonical_names = set(canonical["events"])
    projection_names = set(projection["events"])
    for name in sorted(canonical_names - projection_names):
        problems.append(
            f"{where} does not declare the canonical event {name!r} from {CANONICAL}"
        )
    for name in sorted(projection_names - canonical_names):
        problems.append(
            f"{where} declares the event {name!r}, which {CANONICAL} does not; a projection "
            "introduces no event of its own"
        )
    for name in sorted(canonical_names & projection_names):
        source = canonical["events"][name]
        target = projection["events"][name]
        for field in SEMANTIC_FIELDS:
            if target.get(field) != source.get(field):
                problems.append(
                    f"{where}: event {name!r} has {field} {target.get(field)!r}, but the "
                    f"canonical declaration {CANONICAL} has {source.get(field)!r}"
                )


def main():
    root = pathlib.Path(
        os.environ.get("SCENARIO_CONTRACT_CHECKOUT", str(pathlib.Path(__file__).resolve().parents[2]))
    )
    problems = []
    canonical = load_scope(root, CANONICAL, problems)
    if canonical is not None and not canonical["events"]:
        problems.append(
            f"{CANONICAL} declares no events; a projection agreeing with an empty contract "
            "is not a pass"
        )
    projections = [load_scope(root, relative, problems) for relative in PROJECTIONS]
    if canonical is not None:
        for projection in projections:
            if projection is not None:
                compare(canonical, projection, problems)
        topics = {}
        for scope in [scope for scope in (canonical, *projections) if scope is not None]:
            for topic, name in scope["topics"].items():
                other = topics.get(topic)
                if other is not None and other != scope["path"]:
                    problems.append(
                        f"{scope['path']}: event {name!r} uses the topic {topic!r}, which "
                        f"{other} already binds; the scenario's namespaces are separate "
                        "deployments, so their topics are disjoint"
                    )
                else:
                    topics[topic] = scope["path"]
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}")
        sys.exit(1)
    bound = ", ".join([CANONICAL, *PROJECTIONS])
    print(f"scenario contract: {bound} agree; the projections carry the canonical semantics")


main()
