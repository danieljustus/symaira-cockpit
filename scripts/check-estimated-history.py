#!/usr/bin/env python3
"""Synthetic native Claude/Codex pairing; receipt-validated binaries only."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import shlex
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['go', 'rust', 'receipt', 'test-bundle', 'run-root', 'evidence']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    helpers = runpy.run_path(str(Path(__file__).with_name('check-paired-history.py')))
    digest, inventory = helpers['digest'], helpers['inventory']
    repo = Path(__file__).resolve().parents[1]
    root = args.run_root.resolve()
    assert root.is_relative_to(Path('/Volumes/1TB_NVMe_SN850X/Dev/Symaira_Dev/builds'))
    assert not root.exists()
    assert shutil.disk_usage(root.parent).free >= 5 * 1024**3
    receipt_bytes = args.receipt.read_bytes()
    receipt = json.loads(receipt_bytes)
    binaries = {lane: getattr(args, lane).resolve(strict=True) for lane in ['go', 'rust']}
    hashes = {lane: digest(binary) for lane, binary in binaries.items()}
    for lane in binaries:
        assert {c['binary_sha256'] for c in receipt['checks'] if c['lane'] == lane} == {hashes[lane]}
    assert args.test_bundle.is_dir() and args.test_bundle.suffix == '.xctest'
    args.evidence.mkdir(parents=True, exist_ok=True)
    assert not (args.evidence / 'receipt.json').exists()
    paths = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=repo).decode().split('\0')
    source = {p: digest(repo / p) for p in sorted(set(paths)) if p and (repo / p).is_file()}
    bundle = inventory(args.test_bundle)
    (args.evidence / 'source-before.json').write_text(json.dumps(source, indent=2))
    (args.evidence / 'bundle-before.json').write_text(json.dumps(bundle, indent=2))
    root.mkdir()
    for directory in ['preferences', 'host-tmp', 'traps']:
        (root / directory).mkdir()
    now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=40)
    def stamp(n=0):
        return (now + dt.timedelta(seconds=n)).isoformat()
    def counts(i=100, o=20, c=20, r=10):
        return dict(input_tokens=i, output_tokens=o, cached_input_tokens=c, reasoning_output_tokens=r, total_tokens=i+o)
    def meta(identity, **kw):
        return dict(type='session_meta', timestamp=stamp(), payload=dict(id=identity, **kw))
    def context(model):
        return dict(type='turn_context', payload=dict(model=model))
    def event(n=5, total=None, last=None, **kw):
        info = {}
        if total is not None:
            info['total_token_usage'] = total
        if last is not None:
            info['last_token_usage'] = last
        return dict(type='event_msg', timestamp=stamp(n), payload=dict(type='token_count', info=info), **kw)
    def lines(items):
        return ''.join(json.dumps(item, separators=(',', ':')) + '\n' for item in items)
    def claude(identity, model='claude-sonnet-4-5', **kw):
        return dict(type='assistant', timestamp=stamp(5), requestId=identity,
                    message=dict(id=identity, role='assistant', model=model, stop_reason='end_turn',
                                 usage=dict(input_tokens=100, output_tokens=20)), **kw)
    for scenario in ['complete', 'unknown', 'partial', 'quota-error']:
        base = root / scenario
        for directory in ['home', 'data', 'config', 'cache', 'tmp', 'codex/sessions', 'codex/archived_sessions', 'claude/projects/synthetic']:
            (base / directory).mkdir(parents=True, exist_ok=True)
        source_root = base / 'codex'
        original = [meta('synthetic-root'), context('gpt-5.4'), event(total=counts())]
        (source_root / 'sessions/a.jsonl').write_text(lines(original + [event(n=6, total=counts(), last=counts(900, 90, 0, 0))]))
        (source_root / 'archived_sessions/copy.jsonl').write_text(lines(original))
        child = [meta('synthetic-child', forked_from_id='synthetic-root'), context('gpt-5.4'), event(n=1, total=counts()),
                 dict(type='event_msg', timestamp=stamp(2), payload=dict(type='task_started', started_at=now.timestamp()+2)),
                 event(n=3, total=counts(150, 30, 30, 15))]
        (source_root / 'sessions/child.jsonl').write_text(lines(child))
        other = [meta('synthetic-other'), context('gpt-5.4'), event(n=7, last=counts(), costUSD=0),
                 event(n=8, last=counts(), costUSD=0.1000000001)]
        if scenario == 'unknown':
            other += [context('gpt-future'), event(n=9, last=counts())]
        (source_root / 'sessions/z.jsonl').write_text(lines(other) + ('{"partial":' if scenario == 'partial' else ''))
        rows = [claude('estimate'), claude('recorded', costUSD=0.1000000001), claude('zero', costUSD=0)]
        if scenario == 'unknown':
            rows += [claude('unknown', model='claude-future')]
        (base / 'claude/projects/synthetic/a.jsonl').write_text(lines(rows) + ('{"partial":' if scenario == 'partial' else ''))
        (base / 'claude/projects/synthetic/copy.jsonl').write_text(lines([rows[0]]))
        for path in [source_root / 'auth.json', source_root / 'config.toml', base / 'claude/.credentials.json']:
            path.write_text('synthetic must not discover in local-only mode')
    fixtures = {name: inventory(root / name) for name in ['complete', 'unknown', 'partial', 'quota-error']}
    (args.evidence / 'fixtures-before.json').write_text(json.dumps(fixtures, indent=2))
    for name in ['symvault', 'security', 'symbrain', 'symbrain-go']:
        trap = root / 'traps' / name
        trap.write_text('#!/bin/sh\nprintf trap >> ' + shlex.quote(str(root / 'TRAP')) + '\nexit 97\n')
        trap.chmod(0o700)
    env = dict(PATH='/usr/bin:/bin', TZ='UTC', HOME=str(root / 'preferences'), CFFIXED_USER_HOME=str(root / 'preferences'),
               TMPDIR=str(root / 'host-tmp'), ESTIMATED_HISTORY_ROOT=str(root))
    records = []
    def run(name, method, environment):
        command = ['/usr/bin/xcrun', 'xctest', '-XCTest', 'SymCockpitE2ETests.AIUsageEstimatedHistoryPairTests/' + method, str(args.test_bundle)]
        result = subprocess.run(command, env=environment, cwd=root, capture_output=True, timeout=180)
        (args.evidence / (name + '.stdout')).write_bytes(result.stdout)
        (args.evidence / (name + '.stderr')).write_bytes(result.stderr)
        text = result.stdout.decode() + result.stderr.decode()
        passed = re.findall(r"Test Case '-\[([^]]+)\]' passed", text)
        skipped = re.findall(r"Test Case '-\[([^]]+)\]' skipped", text)
        records.append(dict(name=name, command=command, exit=result.returncode, passed=passed, skipped=skipped))
        (args.evidence / 'commands.json').write_text(json.dumps(records, indent=2))
        assert result.returncode == 0 and passed == ['SymCockpitE2ETests.AIUsageEstimatedHistoryPairTests ' + method] and not skipped, name
        assert 'Executed 1 test, with 0 failures' in text
        return text
    # Verify cfprefsd's actual isolated file before any production preference writes.
    env['ESTIMATED_HISTORY_RUNNER'] = str(binaries['go'])
    pids = []
    for phase in ['sentinel', 'write', 'read-revoke', 'read-revoked']:
        text = run('preferences-' + phase, 'testSeparateProcessConsents', dict(env, ESTIMATED_HISTORY_PHASE=phase))
        pids.append(int(re.search(r'pid=(\d+)', text).group(1)))
        persisted = plistlib.loads((root / 'preferences/Estimated.persistence.plist').read_bytes())
        assert persisted['sentinel'] == 'isolated-estimated-history'
        (args.evidence / ('preferences-' + phase + '.json')).write_text(json.dumps(persisted, indent=2))
    assert len(set(pids)) == 4
    for provider in ['claude', 'codex']:
        for suffix in ['HistoryEnabled', 'HistoryOnly']:
            assert persisted['com.symaira.symtune.aiUsage.' + provider + suffix] is False
    for lane, binary in binaries.items():
        profile = root / (lane + '.sb')
        profile.write_text('(version 1)(allow default)(deny network*)'
            '(deny file-read* (subpath "/Users/daniel") (subpath "/Library/Keychains")'
            '(subpath (param "DENIED_CLAUDE")) (subpath (param "DENIED_CODEX")))'
            '(deny file-write*)(allow file-write* (subpath ' + json.dumps(str(root)) + '))'
            '(deny process-exec)(allow process-exec (literal ' + json.dumps(str(binary)) + '))')
        wrapper = root / (lane + '-brain')
        capture = str(args.evidence.resolve() / (lane + '-brain-'))
        wrapper.write_text('#!/bin/sh\nc="$CLAUDE_CONFIG_DIR"; x="$CODEX_HOME"\n'
            '[ "$SYMBRAIN_USAGE_CLAUDE_HISTORY" = 1 ] && c=' + shlex.quote(str(root / 'absent')) + '\n'
            '[ "$SYMBRAIN_USAGE_CODEX_HISTORY" = 1 ] && x=' + shlex.quote(str(root / 'absent')) + '\n'
            'capture=' + shlex.quote(capture) + '$$\n'
            'printf "%s\\n" "$@" > "$capture.args"\n'
            'printf "%s,%s,%s,%s\\n" "$SYMBRAIN_USAGE_CLAUDE_HISTORY" "$SYMBRAIN_USAGE_CLAUDE_HISTORY_ONLY" "$SYMBRAIN_USAGE_CODEX_HISTORY" "$SYMBRAIN_USAGE_CODEX_HISTORY_ONLY" > "$capture.flags"\n'
            '/usr/bin/sandbox-exec -D DENIED_CLAUDE="$c" -D DENIED_CODEX="$x" -f ' + shlex.quote(str(profile)) + ' ' + shlex.quote(str(binary)) +
            ' "$@" > "$capture.stdout.json" 2> "$capture.stderr"\nstatus=$?\n/bin/cat "$capture.stdout.json"\n/bin/cat "$capture.stderr" >&2\nexit "$status"\n')
        wrapper.chmod(0o700)
        run(lane + '-paired', 'testNativeClientServiceModelAndOverview', dict(env, ESTIMATED_HISTORY_RUNNER=str(wrapper)))
    assert fixtures == {name: inventory(root / name) for name in fixtures}
    assert not (root / 'TRAP').exists()
    assert source == {p: digest(repo / p) for p in source}
    assert bundle == inventory(args.test_bundle)
    assert hashes == {lane: digest(binary) for lane, binary in binaries.items()}
    result = dict(source_class='synthetic canonical local JSONL through native production Swift client/service/view-model and Go/Rust',
                  binaries=hashes, parent_receipt_sha256=hashlib.sha256(receipt_bytes).hexdigest(),
                  records=records, preference_pids=pids, source_unchanged=True, bundle_unchanged=True, fixtures_unchanged=True, skips=0)
    (args.evidence / 'receipt.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(dict(executed=len(records), skips=0, source_unchanged=True)))


if __name__ == '__main__':
    main()
