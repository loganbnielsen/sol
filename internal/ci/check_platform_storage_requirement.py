import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
import tfconfig

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
module = root / 'platform/cloud/modules/platform/main.tf'
declaration = root / 'cli/lib/cloud/sol_cli_platform_storage.ml'
components_json = root / 'platform/shared/components.json'
variables = sorted(root.glob('platform/cloud/*/platform/variables.tf'))

problems = []

for path, what in ((module, 'the platform module'), (declaration, 'the declaration'), (components_json, 'the platform components')):
    if not path.exists():
        problems.append(f'{what} is missing: {path}')
if problems:
    print('\n'.join('FAIL: ' + p for p in problems))
    sys.exit(1)

declared = {}
text = declaration.read_text()
for component, gib, provenance in re.findall(
        r'\{\s*component\s*=\s*"([^"]+)"\s*;\s*gib\s*=\s*(\d+)\s*;\s*provenance\s*=\s*"((?:[^"\\]|\\.)*)"', text, re.S):
    declared[component] = (int(gib), provenance)
if not declared:
    problems.append('the declaration lists no parts at all')
for component, (_gib, provenance) in declared.items():
    if not provenance.strip():
        problems.append(f'the part "{component}" states no provenance')
releases = [r for r in tfconfig.resources(module, kinds=("resource",)) if r.type == "helm_release"]
loki = next((r for r in releases if r.name == "loki"), None)
prometheus = next((r for r in releases if tfconfig.unquote(r.body.get("chart")) == "prometheus"), None)
loki_sets = [tfconfig.unquote(s.get("name")) for s in tfconfig.blocks(loki.body, "set")] if loki else []
if "singleBinary.persistence.enabled" not in loki_sets:
    problems.append("the module no longer declares loki's singleBinary.persistence.enabled, which the declaration assumes")
if prometheus is None:
    problems.append("the module no longer declares the prometheus release, which the declaration assumes")
elif "local.prometheus_component_values" not in str(prometheus.body.get("values", "")):
    problems.append("the prometheus release no longer takes its values from platform/shared/components.json")
layers = json.loads(components_json.read_text()).get("prometheus", {})
switches = [layer.get("alertmanager", {}).get("enabled") for layer in layers.values() if isinstance(layer, dict)]
if layers.get("common", {}).get("alertmanager", {}).get("enabled") is not True or False in switches:
    problems.append("platform/shared/components.json no longer enables the prometheus chart's alertmanager, which the declaration assumes")

for component, (_gib, provenance) in declared.items():
    lowered = ' '.join(provenance.split()).lower()
    if 'chart default' not in lowered and 'observed live' not in lowered:
        problems.append(
            f'the part "{component}" does not attribute its size to the chart or to a live '
            f'observation, but Sol declares no size of its own')
    if 'var.' in lowered and 'chart default' not in lowered:
        problems.append(
            f'the part "{component}" attributes its size to a Sol variable, but Sol sets no '
            f'storage size; either one is declared, or the provenance is wrong')

if problems:
    for problem in problems:
        print('FAIL: ' + problem)
    print(f'platform storage requirement: {len(problems)} problem(s)')
    sys.exit(1)

parts = ', '.join(f'{name} {gib} GiB' for name, (gib, _p) in sorted(declared.items()))
print(
    'platform storage requirement: ' + parts + '; every part attributes its size to the chart, '
    'and every component the declaration assumes is still enabled by the module')
