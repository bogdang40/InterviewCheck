#!/usr/bin/env python3
"""Exercise app deployment with synthetic bundles and mocked build/signing tools."""

from pathlib import Path
import json
import os
import shlex
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MOCK = r'''#!/usr/bin/python3
import json, os, pathlib, shutil, subprocess, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['DEPLOY_MOCK_LOG'], 'a') as log:
    log.write(json.dumps([name] + args) + '\n')
failure = os.environ.get('DEPLOY_MOCK_FAILURE', '')

def pause(point):
    if os.environ.get('DEPLOY_MOCK_PAUSE') != point: return
    marker = pathlib.Path(os.environ['DEPLOY_MOCK_MARKER'])
    marker.touch()
    gate = pathlib.Path(os.environ['DEPLOY_MOCK_GATE'])
    deadline = time.monotonic() + 15
    while not gate.exists():
        if time.monotonic() > deadline: sys.exit(90)
        time.sleep(0.01)

if name == 'xcodegen':
    pass
elif name == 'xcodebuild':
    derived = pathlib.Path(args[args.index('-derivedDataPath') + 1])
    config = args[args.index('-configuration') + 1]
    bundle = derived / 'Build' / 'Products' / config / 'memanager.app'
    bundle.mkdir(parents=True)
    (bundle / 'version').write_text(os.environ['DEPLOY_MOCK_VERSION'])
elif name == 'mktemp':
    if failure == 'staging': sys.exit(20)
    sys.exit(subprocess.call(['/usr/bin/mktemp'] + args))
elif name == 'ditto':
    pause('copy')
    if failure == 'copy': sys.exit(21)
    shutil.copytree(args[0], args[1])
elif name == 'codesign':
    signing = '--sign' in args
    if signing and os.environ['DEPLOY_MOCK_CONFIG'] == 'Release':
        assert '--deep' not in args
        assert '--entitlements' in args
        assert pathlib.Path(args[args.index('--entitlements') + 1]).is_file()
    elif signing:
        assert '--deep' in args and '--entitlements' not in args
    else:
        assert all(flag in args for flag in ['--verify', '--deep', '--strict'])
    if failure == ('sign' if signing else 'verify'): sys.exit(22)
elif name == 'python3':
    if args[0] != '-':
        assert pathlib.Path(args[0]).name == 'check-source-size.py'
        sys.exit(subprocess.call(['/usr/bin/python3'] + args))
    assert args[0] == '-'
    source, target = map(pathlib.Path, args[1:])
    is_swap = source.name == 'memanager.app' and source.parent.name.startswith('.memanager-release.')
    if is_swap:
        pause('swap')
        if failure in ['collision', 'rename-collision']:
            target.mkdir()
            (target / 'version').write_text('different')
        if failure in ['swap', 'rollback', 'collision', 'rollback-collision']: sys.exit(23)
    if source.name == 'previous.app':
        pause('rollback')
        if failure == 'rollback': sys.exit(24)
        if failure == 'rollback-collision':
            target.mkdir()
            (target / 'version').write_text('different')
    # Run the production rename code, retaining its real atomic filesystem semantics.
    sys.exit(subprocess.call(['/usr/bin/python3'] + args))
'''


class Fixture:
    def __init__(self, root, name, mockdir, config='Release', deploy=None, existing=True):
        self.root = root / name
        self.root.mkdir()
        self.config = config
        self.deploy = deploy or self.root / 'deployment' / 'memanager.app'
        self.deploy.parent.mkdir(exist_ok=True)
        if deploy is None and existing:
            self.deploy.mkdir()
            (self.deploy / 'version').write_text('old')
        self.build = self.root / 'build.app'
        self.build.mkdir()
        (self.build / 'version').write_text(name)
        self.entitlements = self.root / 'memanager' / 'memanager.entitlements'
        self.entitlements.parent.mkdir()
        self.entitlements.write_text('mock entitlements')
        self.log = self.root / 'calls.jsonl'
        self.marker = self.root / 'paused'
        self.gate = self.root / 'continue'
        self.env = os.environ.copy()
        self.env.update(PATH=str(mockdir) + ':' + self.env['PATH'],
                        DEPLOY_MOCK_LOG=str(self.log), DEPLOY_MOCK_CONFIG=config,
                        DEPLOY_MOCK_VERSION=name, DEPLOY_MOCK_MARKER=str(self.marker),
                        DEPLOY_MOCK_GATE=str(self.gate))

    def command(self, adhoc=1, wrapper=False):
        if not wrapper:
            return ['/bin/bash', str(ROOT / 'scripts/deploy-app.sh'), str(self.build),
                    str(self.deploy), str(adhoc), str(self.entitlements), self.config]
        scripts = self.root / 'scripts'
        scripts.mkdir(exist_ok=True)
        name = 'build-' + self.config.lower() + '.sh'
        source = (ROOT / 'scripts' / name).read_text()
        old_target = 'DEPLOY_TARGET="$HOME/Applications/InterviewCheck.app"'
        assert source.count(old_target) == 1
        source = source.replace(old_target, 'DEPLOY_TARGET=' + shlex.quote(str(self.deploy)))
        # Keep the real user's environment and log untouched, even in debug cases.
        source = source.replace('"$HOME/Desktop/deepgram_debug.log"',
                                shlex.quote(str(self.root / 'debug.log')))
        (scripts / name).write_text(source)
        (scripts / 'deploy-app.sh').write_text((ROOT / 'scripts/deploy-app.sh').read_text())
        (scripts / 'check-source-size.py').write_text((ROOT / 'scripts/check-source-size.py').read_text())
        for dependency in ['sync-entitlements.sh', 'verify-entitlements.sh']:
            path = scripts / dependency
            path.write_text('#!/bin/bash\nexit 0\n')
            path.chmod(0o755)
        self.env['MEMANAGER_DEVELOPMENT_TEAM'] = '' if adhoc else 'MOCKTEAM'
        return ['/bin/bash', str(scripts / name)]

    def run(self, failure='', adhoc=1, wrapper=False):
        self.env['DEPLOY_MOCK_FAILURE'] = failure
        return subprocess.run(self.command(adhoc, wrapper), env=self.env,
                              capture_output=True, text=True, timeout=20)

    def start(self, pause, failure='', wrapper=False):
        self.env.update(DEPLOY_MOCK_FAILURE=failure, DEPLOY_MOCK_PAUSE=pause)
        return subprocess.Popen(self.command(wrapper=wrapper), env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def staging(self):
        return list(self.deploy.parent.glob('.memanager-release.*'))

    def lock(self):
        return self.deploy.parent / '.memanager-deployment.lock'


def wait_for_marker(fixture, process):
    deadline = time.monotonic() + 10
    while not fixture.marker.exists():
        assert process.poll() is None, process.communicate()
        assert time.monotonic() < deadline, 'Timed out waiting for mocked deployment'
        time.sleep(0.01)


def finish(process):
    try:
        return process.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise


def check_scenarios(root, mockdir):
    scenarios = [
        ('ad hoc success', '', 1, True), ('team signature preserved', '', 0, True),
        ('first install', '', 1, False), ('copy failure', 'copy', 1, True),
        ('signature failure', 'sign', 1, True), ('verification failure', 'verify', 1, True),
        ('swap failure restores old app', 'swap', 1, True),
        ('rollback failure preserves old app', 'rollback', 1, True),
        ('staging failure releases lock', 'staging', 1, True),
        ('different installed bundle survives failed recovery', 'collision', 1, True),
        ('noncooperating bundle survives final rename', 'rename-collision', 1, True),
        ('noncooperating bundle survives rollback rename', 'rollback-collision', 1, True)
    ]
    for name, failure, adhoc, existing in scenarios:
        fixture = Fixture(root, name, mockdir, existing=existing)
        result = fixture.run(failure, adhoc)
        assert (result.returncode == 0) == (failure == ''), (name, result)
        assert not fixture.lock().exists(), name
        if failure in ['rollback', 'collision', 'rename-collision', 'rollback-collision']:
            if failure != 'rollback':
                assert (fixture.deploy / 'version').read_text() == 'different', name
                assert not (fixture.deploy / 'memanager.app').exists(), name
                assert not (fixture.deploy / 'previous.app').exists(), name
            else:
                assert not fixture.deploy.exists(), name
            assert len(fixture.staging()) == 1, name
            previous = fixture.staging()[0] / 'previous.app'
            assert (previous / 'version').read_text() == 'old', name
            assert str(previous) in result.stderr, name
        else:
            assert (fixture.deploy / 'version').read_text() == ('old' if failure else name), name
            assert not fixture.staging(), name
        calls = fixture.calls()
        if not adhoc:
            assert not any(call[0] == 'codesign' and '--sign' in call for call in calls), name
        if failure in ['staging', 'copy', 'sign', 'verify']:
            assert not any(call[0] == 'python3' for call in calls), name
        if not failure:
            verification = next(i for i, call in enumerate(calls) if call[0] == 'codesign' and '--verify' in call)
            movement = next(i for i, call in enumerate(calls) if call[0] == 'python3')
            assert verification < movement, name
        print('PASS: ' + name)
    for adhoc in [0, 1]:
        fixture = Fixture(root, 'debug signing ' + str(adhoc), mockdir, config='Debug')
        result = fixture.run(adhoc=adhoc)
        assert result.returncode == 0, result
        assert (fixture.deploy / 'version').read_text() == fixture.root.name
        assert not fixture.lock().exists() and not fixture.staging()
        if not adhoc:
            assert not any('--sign' in call for call in fixture.calls())
        print('PASS: ' + fixture.root.name)


def check_contention(root, mockdir, owner_config, rival_config, pause='swap', failure=''):
    name = owner_config + ' versus ' + rival_config + ' during ' + pause
    owner = Fixture(root, name, mockdir, config=owner_config)
    rival = Fixture(root, name + ' rival', mockdir, config=rival_config, deploy=owner.deploy)
    process = owner.start(pause, failure=failure, wrapper=True)
    try:
        wait_for_marker(owner, process)
        assert owner.lock().is_dir()
        staged = owner.staging()
        result = rival.run(wrapper=True)
        assert result.returncode != 0 and 'Another deployment owns' in result.stderr, result
        assert owner.lock().is_dir() and owner.staging() == staged
        assert not any(call[0] in ['ditto', 'codesign'] or call[:2] == ['python3', '-']
                       for call in rival.calls())
        owner.gate.touch()
        output = finish(process)
        assert (process.returncode == 0) == (not failure), output
        assert not owner.lock().exists() and not owner.staging()
        assert (owner.deploy / 'version').read_text() == ('old' if failure else name)
        assert not (owner.deploy / 'memanager.app').exists()
        # The losing caller can retry after the first process releases its lock.
        result = rival.run()
        assert result.returncode == 0, result
        assert (owner.deploy / 'version').read_text() == rival.root.name
        assert not owner.lock().exists() and not owner.staging()
        print('PASS: ' + name)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            finish(process)


def check_termination(root, mockdir, pause):
    name = 'termination during ' + pause + ' releases lock and restores deployment'
    fixture = Fixture(root, name, mockdir)
    process = fixture.start(pause)
    try:
        wait_for_marker(fixture, process)
        os.killpg(process.pid, signal.SIGTERM)
        finish(process)
        assert process.returncode == 143, process.returncode
        assert (fixture.deploy / 'version').read_text() == 'old'
        assert not fixture.lock().exists() and not fixture.staging()
        print('PASS: ' + name)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            finish(process)


def check_source_size_gate(root, mockdir, config):
    name = config + ' rejects oversized source before building or deploying'
    fixture = Fixture(root, name, mockdir, config=config)
    source = fixture.root / 'memanager' / 'Oversized.swift'
    source.write_text(''.join(f'let value{index} = {index}\n' for index in range(401)))
    result = fixture.run(wrapper=True)
    assert result.returncode != 0 and 'Source files exceed 400 lines' in result.stderr, result
    assert (fixture.deploy / 'version').read_text() == 'old'
    assert not fixture.lock().exists() and not fixture.staging()
    assert all(call[0] == 'python3' and call[1] != '-' for call in fixture.calls())
    print('PASS: ' + name)


def main():
    with tempfile.TemporaryDirectory(prefix='memanager-deployment-check-') as scratch:
        root = Path(scratch)
        mockdir = root / 'bin'
        mockdir.mkdir()
        for tool in ['ditto', 'codesign', 'python3', 'mktemp', 'xcodegen', 'xcodebuild']:
            path = mockdir / tool
            path.write_text(MOCK)
            path.chmod(0o755)
        check_scenarios(root, mockdir)
        for config in ['Release', 'Debug']:
            check_source_size_gate(root, mockdir, config)
        for owner in ['Release', 'Debug']:
            for rival in ['Release', 'Debug']:
                check_contention(root, mockdir, owner, rival)
        check_contention(root, mockdir, 'Release', 'Debug', pause='copy')
        check_contention(root, mockdir, 'Release', 'Debug', pause='rollback', failure='swap')
        for pause in ['copy', 'swap']:
            check_termination(root, mockdir, pause)


if __name__ == '__main__':
    main()
