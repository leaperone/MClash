#!/usr/bin/env python3
"""Check release evidence against clean source and exact core provenance."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().with_name('xray-release-preflight.sh')
CAPABILITIES = ['nodeSources', 'groupSelect', 'groupFallback', 'groupURLTest', 'routingRules', 'httpIngress', 'socksIngress', 'dnsPolicy']


def git(root, *arguments):
    return subprocess.check_output(['git', '-C', str(root), *arguments], text=True, stderr=subprocess.DEVNULL).strip()


def setup(root):
    for name in ['Support', 'ReleaseNotes', 'ReleaseEvidence']:
        (root / name).mkdir()
    git(root, 'init', '-b', 'test-main')
    git(root, 'config', 'user.name', 'Release test')
    git(root, 'config', 'user.email', 'test@example.invalid')
    (root / 'Support/xray.env').write_text('XRAY_VERSION=26.9.9\nXRAY_REVISION=fixture\nXRAY_RAW_SHA256=hash\n')
    (root / 'ReleaseNotes/1.6.0-rc.1.md').write_text('# Test release\n')
    (root / 'code.swift').write_text('baseline\n')
    git(root, 'add', '.')
    git(root, 'commit', '-m', 'source')
    return dict(schema_version=1, release_version='1.6.0-rc.1', status='passed', backend='xray',
                commit=git(root, 'rev-parse', 'HEAD'), xray_version='26.9.9', xray_revision='fixture',
                xray_raw_sha256='hash', capabilities=CAPABILITIES, validation_commands=['fixture-test'])


def record(root, evidence):
    (root / 'ReleaseEvidence/1.6.0-rc.1.json').write_text(json.dumps(evidence))
    git(root, 'add', 'ReleaseEvidence/1.6.0-rc.1.json')
    git(root, 'commit', '-m', 'record evidence')


def check(root, message=None):
    result = subprocess.run(['/bin/zsh', str(SCRIPT), '1.6.0-rc.1'], capture_output=True, text=True,
                            env={**os.environ, 'MCLASH_RELEASE_PREFLIGHT_REPO_ROOT': str(root)})
    output = result.stdout + result.stderr
    if message is None:
        assert result.returncode == 0 and 'preflight passed' in output, output
    else:
        assert result.returncode != 0 and message in output, output


cases = [
    ('valid', None, None),
    ('pin', {'xray_revision': 'wrong'}, 'xray_revision'),
    ('hash', {'xray_raw_sha256': 'wrong'}, 'xray_raw_sha256'),
    ('capabilities', {'capabilities': ['nodeSources']}, 'missing required Xray runtime capabilities'),
    ('stale', {'commit': '0' * 40}, 'Evidence must match HEAD'),
    ('failed', {'status': 'failed'}, 'status'),
    ('commands', {'validation_commands': []}, 'actual validation commands'),
    ('dirty', None, 'clean worktree'),
    ('staged', None, 'clean worktree'),
    ('untracked', None, 'clean worktree'),
    ('source_changed', None, 'Evidence must match HEAD'),
]
for name, changes, error in cases:
    with tempfile.TemporaryDirectory(prefix='mclash-release-gate-') as directory:
        root = Path(directory)
        evidence = setup(root)
        evidence.update(changes or {})
        record(root, evidence)
        if name in ['dirty', 'staged', 'source_changed']:
            (root / 'code.swift').write_text('changed source\n')
            if name != 'dirty':
                git(root, 'add', 'code.swift')
            if name == 'source_changed':
                git(root, 'commit', '-m', 'untested source')
        if name == 'untracked':
            (root / 'extra.swift').write_text('untracked source\n')
        check(root, error)
        print('PASS', name)

with tempfile.TemporaryDirectory(prefix='mclash-release-gate-') as directory:
    root = Path(directory)
    evidence = setup(root)
    git(root, 'checkout', '-b', 'side')
    (root / 'side.swift').write_text('side source\n')
    git(root, 'add', '.')
    git(root, 'commit', '-m', 'side source')
    git(root, 'checkout', 'test-main')
    record(root, evidence)
    git(root, 'merge', '--no-ff', 'side', '-m', 'merge')
    check(root, 'cannot be a merge commit')
    print('PASS merge evidence rejection')

print('Xray release preflight tests passed')
