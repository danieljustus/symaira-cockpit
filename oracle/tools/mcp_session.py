#!/usr/bin/env python3
"""Record one MCP stdio session against `<bin> serve` (run with python3 -I).

  mcp_session.py BIN RAWDIR OUTDIR INIT_PARAMS.json TOOL [TOOL ...]

Environment is inherited (the capture script isolates it). Sends `initialize`,
`notifications/initialized`, `tools/list`, then `tools/call` with `{}` for each
TOOL. Raw frames (both directions) and stderr go to RAWDIR only; OUTDIR gets
  mcp-tools-list.json                the `result` of tools/list, exact values,
                                     object keys sorted (server order is random)
  mcp-call-<tool>.shape.json         shape of result.content[0].text if JSON,
                                     else of `result`
Exits 1 on any protocol failure so the caller cannot record a partial session.
"""
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shape as shapelib  # noqa: E402  (same directory, loaded explicitly)

TIMEOUT = 60


def main(argv):
    if len(argv) < 6:
        print(__doc__, file=sys.stderr)
        return 2
    binary, rawdir, outdir, init_path, *tools = argv[1:]
    with open(init_path, encoding="utf-8") as f:
        init_params = json.load(f)

    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": init_params},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ] + [
        {"jsonrpc": "2.0", "id": 10 + i, "method": "tools/call",
         "params": {"name": t, "arguments": {}}}
        for i, t in enumerate(tools)
    ]
    wire = "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in requests)
    # stdin closes after the last request: the server exits on EOF.
    proc = subprocess.run([binary, "serve"], input=wire, capture_output=True,
                          text=True, timeout=TIMEOUT)
    with open(os.path.join(rawdir, "mcp-session.requests.ndjson"), "w", encoding="utf-8") as f:
        f.write(wire)
    with open(os.path.join(rawdir, "mcp-session.responses.ndjson"), "w", encoding="utf-8") as f:
        f.write(proc.stdout)
    with open(os.path.join(rawdir, "mcp-session.stderr"), "w", encoding="utf-8") as f:
        f.write(proc.stderr)
    with open(os.path.join(rawdir, "mcp-session.exit"), "w", encoding="utf-8") as f:
        f.write(f"{proc.returncode}\n")

    # Zero stdio pollution: every stdout line must be a JSON-RPC response.
    responses = {}
    for line in proc.stdout.split("\n"):
        if not line:
            continue
        msg = json.loads(line)
        assert msg.get("jsonrpc") == "2.0" and "id" in msg, f"not a response: {line[:80]}"
        responses[msg["id"]] = msg
    for r in requests:
        if "id" in r:
            assert r["id"] in responses, f"no response for {r['method']}"
            assert "error" not in responses[r["id"]], f"{r['method']}: {responses[r['id']]['error']}"

    listed = [t["name"] for t in responses[2]["result"]["tools"]]
    for t in tools:
        assert t in listed, f"tool {t} not in tools/list"

    with open(os.path.join(outdir, "mcp-tools-list.json"), "w", encoding="utf-8") as f:
        # sort_keys: the Swift server emits object keys in per-process random order.
        f.write(json.dumps(responses[2]["result"], indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    for i, t in enumerate(tools):
        result = responses[10 + i]["result"]
        assert result.get("isError") is False, f"{t}: isError {result.get('isError')!r}"
        try:
            target = json.loads(result["content"][0]["text"])
        except (ValueError, KeyError, IndexError, TypeError):
            target = result
        shapelib.conflicts.clear()
        text = shapelib.dumps(shapelib.shape(target))
        for c in shapelib.conflicts:
            print(f"mcp_session.py: {t}: conflict {c}", file=sys.stderr)
        with open(os.path.join(outdir, f"mcp-call-{t}.shape.json"), "w", encoding="utf-8") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
