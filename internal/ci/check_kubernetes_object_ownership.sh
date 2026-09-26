#!/usr/bin/env bash
# One Kubernetes object has one Terraform owner (FND-0061).
#
# Two Terraform resources may not resolve to the same (kind, namespace, name): whichever applies
# second fails with `already exists`, and the object's ownership becomes whatever Terraform state
# happens to hold. FND-0061 was exactly that -- two `kubernetes_role_binding` resources writing
# `sol-platform-provisioner`, and a second pair writing `sol-platform-provisioner-cluster` -- so
# the GCP provisioner's authority could never be created on a fresh target.
#
# The check is static and structural. It does not read a plan or a cluster: it compares what the
# configuration *declares*. Two resources are treated as the same object when their Kubernetes
# kind matches and their `metadata.name` and namespace expressions are the same text (an
# expression like `each.key` is the same instance set when it is the same expression). Names it
# cannot resolve statically are recorded, not guessed at.
#
# The invariant's only exception is an object two resources are *intentionally* both managing;
# that must be said out loud, on both blocks:
#
#   # same-object-owner: <why two Terraform resources own one object here>
#
# Usage: internal/ci/check_kubernetes_object_ownership.sh [repo-root]
set -euo pipefail

root="${1:-.}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: this check needs python3 to read HCL structurally" >&2
  exit 1
fi

python3 - "$root" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])

# The platform's Kubernetes objects live in the platform module; the provider roots that consume
# it are thin, but they are scanned too so a root-level declaration cannot escape the rule.
files = sorted(
    set(root.glob('platform/cloud/modules/platform/*.tf'))
    | set(root.glob('platform/cloud/*/platform/*.tf'))
)
if not files:
    print('FAIL: no platform Terraform files found under', root)
    sys.exit(1)

# `kubernetes_role_binding` -> `rolebinding`, `kubernetes_cluster_role_binding` ->
# `clusterrolebinding`: the kind as Kubernetes sees it, so `kubernetes_role` and
# `kubernetes_cluster_role` do not collide with each other by accident.
def kind_of(resource_type):
    if not resource_type.startswith('kubernetes_'):
        return None
    return resource_type[len('kubernetes_'):].replace('_', '')

def attr_in(text, attr):
    """The value text of `attr = <value>` in text, stopping at the value's own end.

    Handles both multi-line metadata and the inline `metadata { name = "x" }` form, and refuses
    to swallow a closing brace or the next attribute -- an over-eager match would produce a name
    no other declaration could equal, quietly *missing* a real collision.
    """
    m = re.search(r'\b%s\s*=\s*("(?:[^"]*)"|[^\s,}\]]+)' % re.escape(attr), text)
    return m.group(1) if m else None

def matching_brace(text, open_index):
    """The index of the `}` closing the `{` at open_index."""
    depth, i = 1, open_index + 1
    while i < len(text) and depth:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
        i += 1
    return i - 1

def metadata_attr(block, attr):
    """The value text of `attr = ...` inside the block's brace-matched `metadata { ... }`."""
    m = re.search(r'\bmetadata\s*\{', block)
    if not m:
        return None
    return attr_in(block[m.end():matching_brace(block, m.end() - 1)], attr)

def unquote(expr):
    """A quoted literal, unquoted; anything else is returned as-is (an expression)."""
    if expr is None:
        return None
    m = re.fullmatch(r'"([^"]*)"', expr.strip())
    return m.group(1) if m else expr.strip()

# Collect resources. The brace matcher is deliberately shallow: HCL blocks are balanced by
# construction here, and a mis-count would only ever cause a missed finding, never a false one.
resource_re = re.compile(
    r'^resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', re.M)
objects = []
for path in files:
    text = path.read_text()
    for m in resource_re.finditer(text):
        rtype, rname = m.group(1), m.group(2)
        kind = kind_of(rtype)
        if kind is None:
            continue
        block = text[m.end():matching_brace(text, m.end() - 1)]
        name = unquote(metadata_attr(block, 'name'))
        namespace = unquote(metadata_attr(block, 'namespace'))
        if namespace is None:
            namespace = unquote(attr_in(block, 'namespace'))
        if name is None:
            # `generate_name` or a computed name: identity is not knowable statically.
            objects.append(dict(path=path, rtype=rtype, rname=rname, kind=kind,
                                name=None, namespace=namespace, deliberate=False,
                                line=text[:m.start()].count('\n') + 1))
            continue
        deliberate = 'same-object-owner:' in block
        objects.append(dict(path=path, rtype=rtype, rname=rname, kind=kind,
                            name=name, namespace=namespace, deliberate=deliberate,
                            line=text[:m.start()].count('\n') + 1))

named = [o for o in objects if o['name'] is not None]
dynamic = [o for o in objects if o['name'] is None]

# Exact collisions: same kind, same literal name, same namespace expression text. That is the
# same instance set by construction, whichever expression it is.
buckets = {}
for o in named:
    buckets.setdefault((o['kind'], o['name'], o['namespace']), []).append(o)

collisions = []
for key, group in sorted(buckets.items()):
    if len(group) < 2:
        continue
    if all(o['deliberate'] for o in group):
        continue
    collisions.append((key, group))

# Same kind and name, *different* namespace expressions: not decidable here, so it is reported
# rather than passed over or failed.
ambiguous = []
for (kind, name, _ns), group in sorted(buckets.items()):
    same_kind_name = [g for k, g in buckets.items() if k[0] == kind and k[1] == name]
    if len(same_kind_name) > 1 and len(group) == 1:
        others = [o for g in same_kind_name for o in g]
        ambiguous.append(((kind, name), others))

problems = 0
for (kind, name, namespace), group in collisions:
    ns = namespace if namespace is not None else '(unset: the namespace attribute)'
    print('FAIL: %s %r resolves to one Kubernetes object in %s, declared by %d resources:'
          % (kind, name, ns, len(group)))
    for o in sorted(group, key=lambda o: (str(o['path']), o['line'])):
        rel = o['path'].relative_to(root) if str(o['path']).startswith(str(root)) else o['path']
        print('  %s:%d  resource "%s" "%s"' % (rel, o['line'], o['rtype'], o['rname']))
    print('  One object, one Terraform owner: give the subjects one binding, or give the '
          'objects distinct names if their lifetimes really differ.')
    problems += 1

for (kind, name), group in ambiguous:
    print('NOTE: %s %r is named in more than one resource with different namespace '
          'expressions; this check cannot decide whether those resolve to the same namespace:'
          % (kind, name))
    for o in sorted(group, key=lambda o: (str(o['path']), o['line'])):
        rel = o['path'].relative_to(root) if str(o['path']).startswith(str(root)) else o['path']
        print('  %s:%d  resource "%s" "%s" namespace-expression=%s'
              % (rel, o['line'], o['rtype'], o['rname'], o['namespace']))

if dynamic:
    shown = ', '.join(sorted({o['rtype'] for o in dynamic}))
    print('recorded: %d Kubernetes resource(s) with names this check cannot resolve statically '
          '(generate_name, an interpolation, or a reference): %s' % (len(dynamic), shown))

if problems:
    print('kubernetes-object-ownership: %d collision(s)' % problems)
    sys.exit(1)

print('kubernetes-object ownership: %d Kubernetes object(s) declared with resolvable names across '
      '%d file(s); no two Terraform resources resolve to one object.' % (len(named), len(files)))
PY
