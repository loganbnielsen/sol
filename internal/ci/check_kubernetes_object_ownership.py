import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig


def kind_of(resource_type):
    if not resource_type.startswith("kubernetes_"):
        return None
    return resource_type[len("kubernetes_"):].replace("_", "")


def identity(value):
    if value is None:
        return None
    if tfconfig.is_string_literal(value):
        return tfconfig.unquote(value)
    text = str(value)
    if text.startswith("${") and text.endswith("}"):
        return text[2:-1]
    return text


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = sorted(
        set(root.glob("platform/cloud/modules/platform/*.tf"))
        | set(root.glob("platform/cloud/*/platform/*.tf"))
    )
    if not files:
        print("FAIL: no platform Terraform files found under", root)
        sys.exit(1)
    named, dynamic = [], []
    for path in files:
        for r in tfconfig.resources(path, kinds=("resource",)):
            kind = kind_of(r.type)
            if kind is None:
                continue
            metadata = (tfconfig.blocks(r.body, "metadata") or [{}])[0]
            name = identity(metadata.get("name"))
            namespace = identity(metadata.get("namespace", r.body.get("namespace")))
            entry = dict(resource=r, kind=kind, name=name, namespace=namespace)
            (dynamic if name is None else named).append(entry)
    buckets = {}
    for o in named:
        buckets.setdefault((o["kind"], o["name"], o["namespace"]), []).append(o)
    collisions = [(key, group) for key, group in sorted(buckets.items(), key=str) if len(group) > 1]
    ambiguous = []
    for (kind, name, _ns), group in sorted(buckets.items(), key=str):
        same = [g for k, g in buckets.items() if k[0] == kind and k[1] == name]
        if len(same) > 1 and len(group) == 1:
            ambiguous.append(((kind, name), [o for g in same for o in g]))

    def where(o):
        r = o["resource"]
        rel = r.path.relative_to(root) if str(r.path).startswith(str(root)) else r.path
        return f'{rel}:{r.line}  resource "{r.type}" "{r.name}"'

    def ordered(group):
        return sorted(group, key=lambda o: (str(o["resource"].path), o["resource"].line))

    for (kind, name, namespace), group in collisions:
        ns = namespace if namespace is not None else "(unset: the namespace attribute)"
        print(f"FAIL: {kind} {name!r} resolves to one Kubernetes object in {ns}, declared by {len(group)} resources:")
        for o in ordered(group):
            print(f"  {where(o)}")
        print(
            "  One object, one Terraform owner: give the subjects one binding, or give the "
            "objects distinct names if their lifetimes really differ."
        )
    for (kind, name), group in ambiguous:
        print(
            f"NOTE: {kind} {name!r} is named in more than one resource with different namespace "
            "expressions; this check cannot decide whether those resolve to the same namespace:"
        )
        for o in ordered(group):
            print(f"  {where(o)} namespace-expression={o['namespace']}")
    if dynamic:
        shown = ", ".join(sorted({o["resource"].type for o in dynamic}))
        print(
            f"recorded: {len(dynamic)} Kubernetes resource(s) with names this check cannot resolve "
            f"statically (generate_name, an interpolation, or a reference): {shown}"
        )
    if collisions:
        print(f"kubernetes-object-ownership: {len(collisions)} collision(s)")
        sys.exit(1)
    print(
        f"kubernetes-object ownership: {len(named)} Kubernetes object(s) declared with resolvable "
        f"names across {len(files)} file(s); no two Terraform resources resolve to one object."
    )


main()
