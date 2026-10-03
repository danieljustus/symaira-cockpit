#!/usr/bin/env python3
"""Local SwiftPM coverage measurement; never changes tracked files."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time


def parse_lcov(text, allowed):
    hits = {}
    filename = None
    for line in text.splitlines():
        if line.startswith("SF:"):
            filename = str(Path(line[3:]).resolve())
        elif line.startswith("DA:") and filename in allowed:
            number, count, *_ = line[3:].split(",")
            key = (allowed[filename], int(number))
            hits[key] = max(hits.get(key, 0), int(count))
    return hits


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("package", choices=["root", "tune", "history"])
    parser.add_argument("--skip-hardware-writes", action="store_true")
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    package = repo if args.package == "root" else repo / args.package
    environment = dict(os.environ)
    home = Path(os.environ.get("COCKPIT_COVERAGE_HOME", str(output / "isolated-home")))
    home.mkdir(exist_ok=True)
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home))
    for name in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "LLVM_PROFILE_FILE"):
        environment.pop(name, None)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    tracked = subprocess.check_output(["git", "ls-files", "*.swift"], cwd=repo, text=True).splitlines()
    source_paths = [path for path in tracked if "Sources" in Path(path).parts and "Tests" not in Path(path).parts]
    allowed = {str((repo / path).resolve()): path for path in source_paths}
    command = ["swift", "test", "--enable-code-coverage", "--jobs", "2"]
    if args.skip_hardware_writes and args.package == "tune":
        command.extend(["--skip", "WriteSurfaceTests"])
    start = time.monotonic()
    result = subprocess.run(command, cwd=package, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=540)
    elapsed = time.monotonic() - start
    log = output / (args.package + "-tests.log")
    log.write_text(result.stdout)
    if result.returncode:
        print(json.dumps({"package": args.package, "test_exit": result.returncode, "log": str(log), "seconds": elapsed}))
        raise SystemExit(result.returncode)
    aggregates = re.findall(r"Test Suite '(?:All tests|Selected tests)' passed[^\n]*\n\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", result.stdout)
    if not aggregates:
        raise RuntimeError("No verified XCTest aggregate in " + str(log))
    tests = sum(int(row[0]) for row in aggregates)
    skipped = sum(int(row[1] or 0) for row in aggregates)
    failures = sum(int(row[2]) for row in aggregates)
    assert failures == 0
    binary_directory = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=package, env=environment, text=True).strip())
    profiles = list((binary_directory / "codecov").glob("default.profdata"))
    if not profiles:
        profiles = list((package / ".build").rglob("default.profdata"))
    assert len(profiles) == 1, profiles
    binaries = []
    for bundle in binary_directory.glob("*.xctest"):
        executable = bundle / "Contents" / "MacOS" / bundle.stem
        if executable.is_file():
            binaries.append(executable)
    products = ["symcockpit", "SymCockpitApp"] if args.package == "root" else (["symtune", "SymTuneApp"] if args.package == "tune" else [])
    binaries.extend(binary_directory / product for product in products if (binary_directory / product).is_file())
    assert binaries, binary_directory
    export = ["xcrun", "llvm-cov", "export", "--format=lcov", str(binaries[0]), "-instr-profile=" + str(profiles[0])]
    for binary in binaries[1:]:
        export.extend(["-object", str(binary)])
    coverage = subprocess.run(export, cwd=package, env=environment, capture_output=True, text=True, timeout=60)
    (output / (args.package + "-coverage-warnings.log")).write_text(coverage.stderr)
    assert coverage.returncode == 0, coverage.stderr
    (output / (args.package + ".lcov")).write_text(coverage.stdout)
    hits = parse_lcov(coverage.stdout, allowed)
    assert hits, "No repository production-source coverage mapped"
    durations = [(name, float(seconds)) for name, seconds in re.findall(r"Test Case '-\[([^\]]+)\]' passed \(([0-9.]+) seconds\)", result.stdout)]
    record = {
        "repo": str(repo), "head": head, "package": args.package,
        "command": command, "test_exit": result.returncode, "tests": int(tests), "skipped": int(skipped or 0), "failures": int(failures),
        "seconds": elapsed, "log": str(log), "profile": str(profiles[0]),
        "objects": [str(binary) for binary in binaries],
        "lines": [[path, number, count] for (path, number), count in sorted(hits.items())],
        "slow_tests": sorted([(name, seconds) for name, seconds in durations if seconds > 0.5], key=lambda row: -row[1]),
        "coverage_warnings": coverage.stderr,
    }
    destination = output / (args.package + ".json")
    destination.write_text(json.dumps(record, indent=2))
    print(json.dumps({key: record[key] for key in ("package", "head", "tests", "skipped", "failures", "seconds", "log")}, indent=2))
    print("Mapped executable production lines:", len(hits), "covered:", sum(count > 0 for count in hits.values()))


if __name__ == "__main__":
    # One small executable check protects deduplication and zero-count lines.
    assert parse_lcov("SF:/probe.swift\nDA:1,0\nDA:2,3\nDA:2,5\n", {"/probe.swift": "Sources/probe.swift"}) == {("Sources/probe.swift", 1): 0, ("Sources/probe.swift", 2): 5}
    main()
