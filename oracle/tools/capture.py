#!/usr/bin/env python3
"""Record the v0.12 oracle. Called by scripts/oracle-capture.sh (python3 -I).

  capture.py BIN RAWDIR OUTDIR REPO SANDBOX_PROFILE

The case table below is the single source of truth: it produces manifest.json,
runs every case in an isolated environment and writes the fixtures.
Raw stdout/stderr/exit codes go to RAWDIR (outside the repo), fixtures to OUTDIR.

READ-ONLY RULE. Every case below was checked against the source to read state or
to fail in argument parsing before any hardware/file access; the evidence for the
less obvious ones is in the `why` field. Never add a command that writes.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, HERE)
import shape as shapelib  # noqa: E402

CLI = "tuning/Sources/SymCockpitCLI/SymCockpitMain.swift"
READ = "tuning/Sources/SymCockpitCLI/ReadCommands.swift"
ROOT = "Sources/symcockpit/main.swift"

# Static env applied to every case (manifest env.set). Update checks are off:
# SYMTUNE_CHECK_UPDATES=0 (UpdateChecker.isUpdateCheckEnabled) and
# SYMCOCKPIT_CHECK_UPDATES=0 (CockpitUpdatePolicy), so no network request exists.
ENV_SET = {
    "LC_ALL": "C",
    "SYMCOCKPIT_CHECK_UPDATES": "0",
    "SYMTUNE_CHECK_UPDATES": "0",
    "TZ": "UTC",
}
# Exact initialize params of the recorded MCP session (oracle/v0.12/mcp-initialize.json).
MCP_INIT_PARAMS = {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "symcockpit-oracle", "version": "1"}}
VERSION_NORMALIZE = [{"pattern": r"\d+\.\d+\.\d+", "replacement": "<version>"}]

# MCP read tools: `isReadOnly == true` in tuning/Sources/SymCockpitMCP/TuneTools.swift
# (get_capabilities :84-88, get_sensors :95-99, get_battery :106-110,
# list_displays :117-121, get_system_metrics :128-141, get_top_processes :148-157,
# get_ai_usage :190-194, keep_awake_status :274-278, get_brightness :287-291,
# list_profiles :401-405, get_status :433-437, get_history :444-457).
MCP_READ_TOOLS = [
    "get_capabilities", "get_sensors", "get_battery", "list_displays",
    "get_system_metrics", "get_top_processes", "get_ai_usage",
    "keep_awake_status", "get_brightness", "list_profiles", "get_status",
    "get_history",
]
# get_ai_usage calls `symbrain usage` (credential discovery, keychain dialogs).
MCP_NOT_CALLED = {"get_ai_usage": "calls symbrain usage; may raise keychain dialogs"}


def case(id, argv, kind, expect_exit=0, normalize=None, why=""):
    c = {"id": id, "argv": argv, "kind": kind, "expect_exit": expect_exit}
    if kind == "json_shape":
        c["fixture"] = f"cases/{id}.shape.json"
    elif kind == "exact":
        c["fixture"] = f"cases/{id}.stdout"
        c["normalize"] = normalize or []
    return c, why


CASES = [
    # --- root dispatcher (Sources/symcockpit/main.swift) ---
    case("help", ["help"], "exact", why=f"{ROOT}:132-134"),
    case("help-flag", ["--help"], "exact", why=f"{ROOT}:132-134"),
    case("help-short", ["-h"], "exact", why=f"{ROOT}:132-134"),
    case("version", ["version"], "exact", normalize=VERSION_NORMALIZE,
         why=f"{ROOT}:113-131; update check disabled via env, stdout not a tty"),
    case("version-flag", ["--version"], "exact", normalize=VERSION_NORMALIZE, why=f"{ROOT}:113"),
    case("version-short", ["-V"], "exact", normalize=VERSION_NORMALIZE, why=f"{ROOT}:113"),
    case("version-json", ["version", "--json"], "json_shape", why=f"{ROOT}:115-116, 44-91"),
    case("no-args", [], "exit_code", 2, why=f"{ROOT}:99-102"),
    case("unknown-command", ["nope"], "exit_code", 2, why=f"{ROOT}:154-157"),
    case("tune-prefix-removed", ["tune", "sensors"], "exit_code", 2, why=f"{ROOT}:106-112"),
    case("operate-moved", ["operate"], "exit_code", 4, why=f"{ROOT}:135-149 (AGENTS.md: exit 4)"),
    case("scope-moved", ["scope"], "exit_code", 4, why=f"{ROOT}:135-149 (AGENTS.md: exit 4)"),
    # --- read commands, JSON ---
    case("sensors-json", ["sensors", "--json"], "json_shape", why=f"{READ}:61-62"),
    case("battery-json", ["battery", "--json"], "json_shape", why=f"{READ}:63-64"),
    case("displays-json", ["displays", "--json"], "json_shape", why=f"{READ}:65-66"),
    case("permissions-json", ["permissions", "--json"], "json_shape", why=f"{READ}:67-68"),
    case("doctor-json", ["doctor", "--json"], "json_shape",
         why=f"{READ}:59-60; credential_sources are metadata only (AIUsageService.swift:127-137)"),
    case("metrics-json", ["metrics", "--json"], "json_shape", why=f"{CLI}:338-353"),
    case("status-json", ["status", "--json"], "json_shape", why=f"{CLI}:235-247"),
    case("history-json", ["history", "--json"], "json_shape", why=f"{CLI}:292-303"),
    case("processes-json", ["processes", "--json"], "json_shape", why=f"{READ}:86-102"),
    case("top-json", ["top", "--json"], "json_shape", why=f"{READ}:73-74 alias of processes"),
    case("brightness-get", ["brightness", "get"], "json_shape", why=f"{CLI}:396-399 read branch"),
    case("fan-status", ["fan", "status"], "json_shape", why=f"{CLI}:475-477 read"),
    case("fan-profile-read", ["fan", "profile"], "json_shape", why=f"{CLI}:495-500 no name = read"),
    case("fan-target-read", ["fan", "target"], "json_shape", why=f"{CLI}:537-557 no value = read"),
    case("awake-status", ["awake", "status"], "json_shape",
         why=f"{CLI}:151-154; KeepAwakeCoordinator.status() only reads the in-process session"),
    case("profile-list", ["profile", "list"], "json_shape", why=f"{CLI}:214-216 lists the isolated dir"),
    # --- read commands, text ---
    case("history-text", ["history"], "exact",
         why=f"{CLI}:305-308: empty isolated history prints a fixed line"),
    case("status-text", ["status"], "exit_code", 0, why=f"{CLI}:249-287 text holds measurements"),
    case("processes-text", ["processes"], "exit_code", 0, why=f"{READ}:104-107 table holds process names"),
    # --- static help texts (printed before any controller call) ---
    case("sensors-help", ["sensors", "--help"], "exact", why=f"{READ}:46-49"),
    case("battery-help", ["battery", "--help"], "exact", why=f"{READ}:46-49"),
    case("displays-help", ["displays", "--help"], "exact", why=f"{READ}:46-49"),
    case("permissions-help", ["permissions", "--help"], "exact", why=f"{READ}:46-49"),
    case("doctor-help", ["doctor", "--help"], "exact", why=f"{READ}:46-49"),
    case("metrics-help", ["metrics", "--help"], "exact", why=f"{CLI}:339-346"),
    case("history-help", ["history", "--help"], "exact", why=f"{CLI}:293-298"),
    case("processes-help", ["processes", "--help"], "exact", why=f"{READ}:88-91"),
    case("ai-usage-help", ["ai-usage", "--help"], "exact",
         why=f"{READ}:110-127: help branch returns before any symbrain call"),
    case("profile-help", ["profile", "--help"], "exact", why=f"{CLI}:180-186 returns before any action"),
    case("dim-help", ["dim", "--help"], "exact", why=f"{CLI}:436-438 returns before any action"),
    case("warmth-help", ["warmth", "--help"], "exact", why=f"{CLI}:449-451 returns before any action"),
    case("fan-help", ["fan", "--help"], "exact", why=f"{CLI}:462-468 returns before any action"),
    case("battery-limit-help", ["battery-limit", "--help"], "exact",
         why=f"{CLI}:607-609 returns before any action"),
    # --- usage errors: argument parsing throws before any read or write ---
    case("sensors-bad-arg", ["sensors", "--bogus"], "exit_code", 2, why=f"{READ}:19-23, 50-51"),
    case("doctor-bad-arg", ["doctor", "--bogus"], "exit_code", 2, why=f"{READ}:19-23, 50-51"),
    case("metrics-bad-arg", ["metrics", "--bogus"], "exit_code", 2, why=f"{CLI}:349-351"),
    case("status-bad-option", ["status", "--bogus"], "exit_code", 2,
         why="tuning/Sources/SymCockpitCore/StatusOptions.swift:45-46"),
    case("status-interval-missing", ["status", "--interval"], "exit_code", 2,
         why="tuning/Sources/SymCockpitCore/StatusOptions.swift:35-38"),
    case("history-bad-option", ["history", "--bogus"], "exit_code", 2,
         why="tuning/Sources/SymCockpitCore/HistoryOptions.swift:39"),
    case("processes-sort-missing", ["processes", "--sort"], "exit_code", 2,
         why="tuning/Sources/SymCockpitCore/ProcessListingPresentation.swift:70-75"),
    case("processes-bad-limit", ["processes", "--limit", "0"], "exit_code", 2,
         why="tuning/Sources/SymCockpitCore/ProcessListingPresentation.swift:77-82"),
    case("brightness-get-extra", ["brightness", "get", "extra"], "exit_code", 2,
         why=f"{CLI}:396-398 rejectTrailingArguments before the read"),
    case("fan-status-extra", ["fan", "status", "extra"], "exit_code", 2,
         why=f"{CLI}:475-476 rejectTrailingArguments before the read"),
    case("profile-missing-subcommand", ["profile"], "exit_code", 2, why=f"{CLI}:187-189"),
    case("profile-list-extra", ["profile", "list", "extra"], "exit_code", 2,
         why=f"{CLI}:191 rejectTrailingArguments before the switch"),
    case("data-dir-missing-path", ["sensors", "--data-dir"], "exit_code", 2,
         why=f"{CLI}:626-631, 640-644 before the controller exists"),
]
CASE_LIST = [c for c, _ in CASES]


def mcp_cases():
    out = [{"id": "mcp-tools-list", "kind": "mcp_tools_list", "fixture": "cases/mcp-tools-list.json"}]
    for t in MCP_READ_TOOLS:
        if t in MCP_NOT_CALLED:
            continue
        out.append({"id": f"mcp-call-{t}", "kind": "mcp_call_shape", "tool": t, "arguments": {},
                    "fixture": f"cases/mcp-call-{t}.shape.json"})
    return out


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout.strip()


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()


def isolated_env(root, name):
    d = os.path.join(root, name)
    paths = {k: os.path.join(d, k) for k in ("home", "config", "data", "cache")}
    for p in paths.values():
        os.makedirs(p)
    env = {"PATH": "/usr/bin:/bin", "HOME": paths["home"], "CFFIXED_USER_HOME": paths["home"],
           "XDG_CONFIG_HOME": paths["config"], "XDG_DATA_HOME": paths["data"],
           "XDG_CACHE_HOME": paths["cache"], **ENV_SET}
    return env


def run_cli(binary, profile, env, argv, rawbase):
    p = subprocess.run(["/usr/bin/sandbox-exec", "-f", profile, binary, *argv], env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=90)
    for ext, data in (("stdout", p.stdout), ("stderr", p.stderr),
                      ("exit", f"{p.returncode}\n".encode())):
        with open(f"{rawbase}.{ext}", "wb") as f:
            f.write(data)
    return p


def main(argv):
    if len(argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    binary, rawdir, outdir, repo, profile = argv[1:]
    os.makedirs(rawdir, exist_ok=True)
    casesdir = os.path.join(outdir, "cases")
    shutil.rmtree(casesdir, ignore_errors=True)  # this script owns cases/
    os.makedirs(casesdir)

    # Source identity: last commit that touched the Swift sources; they must be clean.
    sources = ["Sources", "tuning", "history", "Package.swift", "Package.resolved"]
    dirty = git(repo, "status", "--porcelain", "--", *sources)
    if dirty:
        print("capture.py: Swift sources are modified; the binary may not match:\n" + dirty, file=sys.stderr)
        return 1
    swift_commit = git(repo, "log", "-1", "--format=%H", "--", *sources)

    failures = []
    tmp = tempfile.mkdtemp(prefix="oracle-")
    try:
        for c, why in CASES:
            env = isolated_env(tmp, c["id"])
            p = run_cli(binary, profile, env, c["argv"], os.path.join(rawdir, c["id"]))
            if p.returncode != c["expect_exit"]:
                hint = " (killed: sandbox denied access to real user data?)" if p.returncode < 0 else ""
                failures.append(f"{c['id']}: exit {p.returncode}, expected {c['expect_exit']}{hint}")
                continue
            fx = os.path.join(outdir, c["fixture"]) if "fixture" in c else None
            if c["kind"] == "json_shape":
                shapelib.conflicts.clear()
                try:
                    text = shapelib.dumps(shapelib.shape(json.loads(p.stdout)))
                except ValueError as e:
                    failures.append(f"{c['id']}: stdout is not JSON ({e})")
                    continue
                if shapelib.conflicts:
                    failures.append(f"{c['id']}: shape conflicts {shapelib.conflicts}")
                    continue
                with open(fx, "w", encoding="utf-8") as f:
                    f.write(text)
            elif c["kind"] == "exact":
                out = p.stdout.decode("utf-8")
                for n in c["normalize"]:
                    out = re.sub(n["pattern"], n["replacement"], out)
                with open(fx, "w", encoding="utf-8", newline="") as f:
                    f.write(out)

        # MCP: one session, default (isolated) configuration = mode "full".
        env = isolated_env(tmp, "mcp")
        tools = [t for t in MCP_READ_TOOLS if t not in MCP_NOT_CALLED]
        init = os.path.join(outdir, "mcp-initialize.json")
        with open(init, "w", encoding="utf-8") as f:
            f.write(json.dumps(MCP_INIT_PARAMS, indent=2) + "\n")
        p = subprocess.run(
            ["/usr/bin/sandbox-exec", "-f", profile, sys.executable, "-I",
             os.path.join(HERE, "mcp_session.py"), binary, rawdir, casesdir, init, *tools],
            env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)
        with open(os.path.join(rawdir, "mcp-session.driver.log"), "w", encoding="utf-8") as f:
            f.write(p.stdout + p.stderr)
        if p.returncode != 0:
            failures.append(f"mcp session failed (exit {p.returncode}): {p.stderr.strip()[-300:]}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("capture.py: FAILED\n  " + "\n  ".join(failures), file=sys.stderr)
        return 1

    version = json.loads(open(os.path.join(rawdir, "version-json.stdout"), encoding="utf-8").read())["version"]
    manifest = {
        "schema": 1,
        "source": {"swift_commit": swift_commit, "version": version,
                   "captured_on": {"arch": sh("uname", "-m"), "macos": sh("sw_vers", "-productVersion")}},
        "env": {"isolate_xdg": True, "set": ENV_SET},
        "cases": CASE_LIST + mcp_cases(),
    }
    with open(os.path.join(outdir, "manifest.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"capture.py: ok, {len(manifest['cases'])} cases, swift_commit {swift_commit}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
