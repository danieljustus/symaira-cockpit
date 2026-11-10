#!/usr/bin/env python3
"""Run opt-in XCTest against receipt-validated native Brains, never user history.

Build the root tests first, then supply the resulting .xctest bundle. All fixture
and HOME directories must be a new run directory beneath Dev/builds or Dev/Symaira_Dev/builds.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import time
from contextlib import closing


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    return {str(p.relative_to(root)): {"bytes": p.stat().st_size, "sha256": digest(p)}
            for p in sorted(root.rglob("*")) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["go", "rust", "receipt", "test-bundle", "run-root", "evidence"]:
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    existing_parent = next(p for p in args.run_root.parents if p.exists())
    assert shutil.disk_usage(existing_parent).free >= 5 * 1024**3, "5 GiB reserve"
    root = args.run_root.resolve()
    assert any(root.is_relative_to(Path(p)) for p in [
        "/Volumes/1TB_NVMe_SN850X/Dev/builds", "/Volumes/1TB_NVMe_SN850X/Dev/Symaira_Dev/builds"])
    assert not root.exists(), "Refuse to overwrite a previous run"
    binaries = {lane: getattr(args, lane).resolve(strict=True) for lane in ["go", "rust"]}
    receipt_bytes = args.receipt.read_bytes()
    receipt = json.loads(receipt_bytes)
    hashes = {}
    for lane, binary in binaries.items():
        expected = {c["binary_sha256"] for c in receipt["checks"] if c["lane"] == lane}
        assert len(expected) == 1 and re.fullmatch("[0-9a-f]{64}", next(iter(expected)))
        hashes[lane] = digest(binary)
        assert expected == {hashes[lane]}, (lane, "final receipt mismatch")
        assert os.access(binary, os.X_OK)
    assert args.test_bundle.is_dir() and args.test_bundle.suffix == ".xctest"
    args.evidence.mkdir(parents=True, exist_ok=True)
    assert not (args.evidence / "receipt.json").exists(), "Retain previous receipt"
    root.mkdir(parents=True)
    records = []
    repo = Path(__file__).resolve().parents[1]
    source_paths = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=repo).decode().split("\0")
    source_before = {p: digest(repo / p) for p in sorted(set(source_paths)) if p and (repo / p).is_file()}
    bundle_before = inventory(args.test_bundle)
    (args.evidence / "source-before.json").write_text(json.dumps(source_before, indent=2) + "\n")
    (args.evidence / "bundle-before.json").write_text(json.dumps(bundle_before, indent=2) + "\n")

    def run(name, command, environment, expected_test=None):
        result = subprocess.run(command, env=environment, cwd=root, capture_output=True, timeout=120)
        (args.evidence / (name + ".stdout")).write_bytes(result.stdout)
        (args.evidence / (name + ".stderr")).write_bytes(result.stderr)
        record = dict(name=name, command=command, exit_code=result.returncode)
        records.append(record)
        (args.evidence / "commands.json").write_text(json.dumps(records, indent=2) + "\n")
        if expected_test:
            text = result.stdout.decode() + result.stderr.decode()
            passed = re.findall(r"Test Case '-\[([^]]+)\]' passed", text)
            skipped = re.findall(r"Test Case '-\[([^]]+)\]' skipped", text)
            record.update(passed=passed, skipped=skipped)
            assert result.returncode == 0 and passed == [expected_test] and not skipped, (name, record)
            assert "Executed 1 test, with 0 failures" in text, (name, "missing executed summary")
        return result

    # Only these synthetic data roots are ever passed to the production Swift client.
    timestamp = int(time.time() * 1000) - 1000
    stamp = datetime.datetime.fromtimestamp(timestamp / 1000, datetime.timezone.utc).isoformat()
    scenarios = ["complete", "missing", "partial", "quota-error"]
    for scenario in scenarios:
        base = root / scenario
        for directory in ["home", "config", "cache", "tmp", "data/opencode", "grok/sessions/synthetic"]:
            (base / directory).mkdir(parents=True)
        usage = dict(inputTokens=10, outputTokens=20)
        if scenario != "missing":
            usage["costUsdTicks"] = 2000000001
        event = dict(timestamp=stamp, params={"_meta": {"eventId": "synthetic-grok"},
                     "update": {"sessionUpdate": "turn_completed", "usage": {"modelUsage": {"grok-model": usage}}}})
        ledger = json.dumps(event).encode() + b"\n"
        if scenario == "partial":
            ledger += b'{"unfinished":'
        (base / "grok/sessions/synthetic/updates.jsonl").write_bytes(ledger)
        data = '{"role":"assistant","providerID":"opencode-go","modelID":"go-model","tokens":{"total":12}'
        if scenario != "missing":
            data += ',"cost":0.1000000001'
        data += '}'
        for channel in ["opencode.db", "opencode-next.db"]:
            with closing(sqlite3.connect(base / "data/opencode" / channel)) as db:
                db.execute("CREATE TABLE message(id TEXT PRIMARY KEY,time_created INTEGER,data TEXT)")
                db.execute("CREATE TABLE session_message(id TEXT PRIMARY KEY,time_created INTEGER,type TEXT,data TEXT)")
                db.execute("INSERT INTO message VALUES(?,?,?)", ("synthetic-message", timestamp, data))
                # Same normalized message in v2 and both channels must count only once.
                v2 = data.replace('"role":"assistant","providerID":"opencode-go","modelID":"go-model"',
                                  '"model":{"providerID":"opencode-go","id":"go-model"}')
                db.execute("INSERT INTO session_message VALUES(?,?,?,?)", ("synthetic-message", timestamp, "assistant", v2))
                if scenario == "partial" and channel == "opencode.db":
                    db.execute("INSERT INTO message VALUES(?,?,?)", ("bad-message", timestamp, '{"role":"assistant"}'))
                db.commit()
    before = {scenario: {part: inventory(root / scenario / part) for part in ["grok", "data"]}
              for scenario in scenarios}
    (args.evidence / "fixtures-before.json").write_text(json.dumps(before, indent=2) + "\n")
    (root / "traps").mkdir()
    for name in ["security", "symvault", "symbrain", "symbrain-go"]:
        trap = root / "traps" / name
        trap.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(name) + " >> " + shlex.quote(str(root / "TRAP")) + "\nexit 97\n")
        trap.chmod(0o700)
    environment = {"PATH": "/usr/bin:/bin", "TZ": "UTC"}
    for directory in ["preferences-home", "host-tmp"]:
        (root / directory).mkdir()
    environment.update(HOME=str(root / "preferences-home"), CFFIXED_USER_HOME=str(root / "preferences-home"),
                       TMPDIR=str(root / "host-tmp"), PAIRED_HISTORY_ROOT=str(root),
                       PAIRED_HISTORY_SUITE=str(root / "preferences-home/PairedHistory.persistence"))
    for lane, binary in binaries.items():
        profile = root / (lane + ".sb")
        profile.write_text('(version 1)(allow default)(deny network*)'
                           '(deny file-read* (subpath (param "DENIED_GROK")) (subpath (param "DENIED_OPENCODE")))'
                           '(deny file-read* (subpath "/Users/daniel") (subpath "/Library/Keychains"))'
                           '(deny file-write*)(allow file-write* (subpath ' + json.dumps(str(root)) + '))'
                           '(deny process-exec)(allow process-exec (literal ' + json.dumps(str(binary)) + '))')
        wrapper = root / (lane + "-brain")
        capture = str(args.evidence.resolve() / (lane + '-brain-'))
        wrapper.write_text('#!/bin/sh\n' +
                           'g="$GROK_HOME"; o="$XDG_DATA_HOME/opencode"\n' +
                           '[ "$SYMBRAIN_USAGE_GROK_HISTORY" = 1 ] && g=' + shlex.quote(str(root / 'absent')) + '\n' +
                           '[ "$SYMBRAIN_USAGE_OPENCODE_HISTORY" = 1 ] && o=' + shlex.quote(str(root / 'absent')) + '\n' +
                           'capture=' + shlex.quote(capture) + '$$\n' +
                           'printf "%s\\n" "$@" > "$capture.args"\n' +
                           '/usr/bin/sandbox-exec -D DENIED_GROK="$g" -D DENIED_OPENCODE="$o" -f ' +
                           shlex.quote(str(profile)) + ' ' + shlex.quote(str(binary)) +
                           ' "$@" > "$capture.stdout.json" 2> "$capture.stderr"\n' +
                           'status=$?\n/bin/cat "$capture.stdout.json"\n/bin/cat "$capture.stderr" >&2\nexit "$status"\n')
        wrapper.chmod(0o700)
        environment["PAIRED_HISTORY_RUNNER"] = str(wrapper)
        run(lane + "-paired", ["/usr/bin/xcrun", "xctest", "-XCTest",
            "SymCockpitE2ETests.AIUsagePairedHistoryTests/testRealBrainClientServiceAndSpend", str(args.test_bundle)],
            environment, "SymCockpitE2ETests.AIUsagePairedHistoryTests testRealBrainClientServiceAndSpend")
    # Three genuinely separate native XCTest processes share only the isolated defaults suite/HOME.
    for phase in ["write", "read-revoke", "read-revoked"]:
        run("preferences-" + phase, ["/usr/bin/xcrun", "xctest", "-XCTest",
            "SymCockpitE2ETests.AIUsagePairedHistoryTests/testSeparateProcessPreferences", str(args.test_bundle)],
            dict(environment, PAIRED_HISTORY_PHASE=phase),
            "SymCockpitE2ETests.AIUsagePairedHistoryTests testSeparateProcessPreferences")
    pids = [int(re.search(rb"pid=(\d+)", (args.evidence / ("preferences-" + p + ".stdout")).read_bytes()).group(1))
            for p in ["write", "read-revoke", "read-revoked"]]
    assert len(set(pids)) == 3
    preference_file = root / "preferences-home/PairedHistory.persistence.plist"
    persisted = plistlib.loads(preference_file.read_bytes())
    prefix = "com.symaira.symtune.aiUsage."
    assert persisted[prefix + "grokHistoryEnabled"] is False
    assert persisted[prefix + "opencodeHistoryEnabled"] is False
    assert persisted[prefix + "localSpendPeriod"] == "yesterday"
    assert persisted[prefix + "localSpendMode"] == "costPerMillion"
    (args.evidence / "isolated-preference-readback.json").write_text(json.dumps(persisted, indent=2) + "\n")
    # Actual denial controls: no connection is attempted beyond the kernel-denied loopback socket.
    profile = root / "rust.sb"
    control_profile = profile.read_text().replace('(param "DENIED_GROK")', json.dumps(str(root / "absent")))
    control_profile = control_profile.replace('(param "DENIED_OPENCODE")', json.dumps(str(root / "absent")))
    control_python = Path(sys.base_prefix) / "Resources/Python.app/Contents/MacOS/Python"
    assert control_python.is_file(), "Need the real framework interpreter, not its posix_spawn launcher"
    control_profile += '(allow process-exec (literal ' + json.dumps(str(control_python)) + ') (literal "/bin/cat"))'
    denied = run("network-denial", ["/usr/bin/sandbox-exec", "-p", control_profile, str(control_python),
                 "-I", "-S", "-c", 'import socket; socket.create_connection(("127.0.0.1", 9), timeout=1)'], environment)
    assert denied.returncode != 0 and b"PermissionError: [Errno 1] Operation not permitted" in denied.stderr
    sentinel = root / "denied-synthetic-sentinel"
    sentinel.write_text("synthetic privacy control only\n")
    denied = run("read-denial", ["/usr/bin/sandbox-exec", "-p", control_profile +
                 '(deny file-read* (literal ' + json.dumps(str(sentinel)) + '))', "/bin/cat", str(sentinel)], environment)
    assert denied.returncode != 0 and not denied.stdout and b"Operation not permitted" in denied.stderr
    denied = run("exec-denial", ["/usr/bin/sandbox-exec", "-p", control_profile, "/usr/bin/security", "help"], environment)
    assert denied.returncode != 0
    after = {scenario: {part: inventory(root / scenario / part) for part in ["grok", "data"]} for scenario in before}
    assert before == after and not (root / "TRAP").exists()
    assert all(not list((root / scenario / "tmp").iterdir()) for scenario in before)
    assert hashes == {lane: digest(binary) for lane, binary in binaries.items()}
    assert source_before == {p: digest(repo / p) for p in source_before}
    assert bundle_before == inventory(args.test_bundle)
    observations = inventory(args.evidence)
    helpers = {str(p): digest(p) for p in [Path('/bin/sh'), Path('/bin/cat'), Path('/usr/bin/sandbox-exec'), control_python]}
    result = dict(source_class="synthetic JSONL and v1/v2 SQLite through native production Swift/Go/Rust",
                  helper_hashes=helpers, observations=observations, bundle_unchanged=True, cockpit_source_unchanged=True,
                  binaries={lane: dict(path=str(binaries[lane]), sha256=hashes[lane]) for lane in binaries},
                  parent_receipt_sha256=hashlib.sha256(receipt_bytes).hexdigest(),
                  fixture_inventory=dict(before=before, after=after), preference_pids=pids,
                  test_executions=5, skips=0, records=records, source_unchanged=True, traps_unused=True)
    (args.evidence / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(dict(paired=2, preferences=3, skips=0, source_unchanged=True, preference_pids=pids)))


if __name__ == "__main__":
    main()
