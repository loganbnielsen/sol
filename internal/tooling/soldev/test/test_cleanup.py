import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    repo = root / 'repo'
    tree = root / 'owned tree'
    tools = root / 'tools'
    repo.mkdir()
    tools.mkdir()
    gh = tools / 'gh'
    gh.write_text('#!/usr/bin/env python3\nimport os\nprint(os.environ["CLEANUP_PR"])\n')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])

    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()

    git('init', '-b', 'main')
    git('remote', 'add', 'origin', 'https://github.com/example/cleanup.git')
    git('config', 'user.email', 'test@example.com')
    git('config', 'user.name', 'Test')
    (repo / '.gitignore').write_text('secret\n')
    git('add', '.gitignore')
    git('commit', '-m', 'initial')
    git('worktree', 'add', '-b', 'feature', str(tree))
    head = git('rev-parse', 'feature')
    info = dict(state='MERGED', headRefName='feature', headRefOid=head,
                isCrossRepository=False, baseRefName='main')

    def run(ok, apply=False, cwd=repo, target=tree):
        env['CLEANUP_PR'] = json.dumps(info)
        result = subprocess.run(
            [binary, 'pipeline', 'cleanup', '123', str(target)] +
            (['--apply'] if apply else []), cwd=cwd, env=env,
            capture_output=True, text=True)
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result.stdout

    assert 'Would remove' in run(True)
    assert tree.exists()
    run(False, cwd=tree)
    nested = tree / 'nested'
    nested.mkdir()
    run(False, cwd=nested)
    nested.rmdir()
    run(False, target=repo)
    git('worktree', 'lock', str(tree))
    run(False, apply=True)
    git('worktree', 'unlock', str(tree))
    for name in ['untracked', 'secret']:
        (tree / name).write_text('preserve')
        run(False, apply=True)
        assert (tree / name).read_text() == 'preserve'
        (tree / name).unlink()
    (tree / '.gitignore').write_text('edited\n')
    run(False, apply=True)
    subprocess.check_call(['git', '-C', str(tree), 'restore', '.gitignore'])
    for key, value in [('state', 'OPEN'), ('headRefName', 'other'),
                       ('headRefOid', '0' * 40), ('isCrossRepository', True),
                       ('baseRefName', 'other')]:
        original = info[key]
        info[key] = value
        run(False, apply=True)
        info[key] = original
    subprocess.check_call(['git', '-C', str(tree), 'commit', '--allow-empty', '-m', 'later'])
    run(False, apply=True)
    subprocess.check_call(['git', '-C', str(tree), 'reset', '--hard', head])
    run(True, apply=True)
    assert not tree.exists()
    assert 'refs/heads/feature' not in git('for-each-ref', '--format=%(refname)')
    run(False, apply=True)
print('cleanup preview, removal, and preservation checks passed')
