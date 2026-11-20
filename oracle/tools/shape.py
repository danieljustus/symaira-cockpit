#!/usr/bin/env python3
"""Derive the structural shape of a JSON document (keys and types only, never values).

Usage (always run with -I):
  python3 -I shape.py [FILE]     read JSON from FILE or stdin, print the shape
  python3 -I shape.py --self-test

Shape form (oracle/README.md):
  {"type":"object","properties":{key: Shape}}   keys sorted
  {"type":"array","items": Shape | null}        null = no element seen
  {"type":"string"|"number"|"boolean"|"null"}   integer and float are both "number"

Array elements are merged into one item shape. Merge rules:
  object+object  union of keys, values merged recursively
  array+array    items merged (null items = empty array, adopts the other side)
  T+T            T
  null+T         T   (null tolerated: an optional value seen as null and as T)
  anything else  conflict: kept first-wins by type name, reported on stderr,
                 exit status 3 when --strict is given
"""
import json
import sys

PRIMITIVES = {"string", "number", "boolean", "null"}
conflicts = []


def shape(value):
    if isinstance(value, bool):  # before int: bool is an int subclass
        return {"type": "boolean"}
    if value is None:
        return {"type": "null"}
    if isinstance(value, (int, float)):
        return {"type": "number"}
    if isinstance(value, str):
        return {"type": "string"}
    if isinstance(value, dict):
        return {"type": "object",
                "properties": {k: shape(value[k]) for k in sorted(value)}}
    if isinstance(value, list):
        items = None
        for element in value:
            items = merge(items, shape(element), "[]")
        return {"type": "array", "items": items}
    raise TypeError(f"unsupported JSON value {type(value).__name__}")


def merge(a, b, path="$"):
    if a is None:
        return b
    if b is None:
        return a
    ta, tb = a["type"], b["type"]
    if ta == tb == "object":
        props = {}
        for k in sorted(set(a["properties"]) | set(b["properties"])):
            props[k] = merge(a["properties"].get(k), b["properties"].get(k), f"{path}.{k}")
        return {"type": "object", "properties": props}
    if ta == tb == "array":
        return {"type": "array", "items": merge(a["items"], b["items"], path + "[]")}
    if ta == tb:
        return a
    if ta == "null":
        return b
    if tb == "null":
        return a
    conflicts.append(f"{path}: {ta} vs {tb}")
    return a if ta < tb else b


def dumps(s):
    return json.dumps(s, indent=2, sort_keys=True) + "\n"


def self_test():
    def eq(got, want, label):
        assert got == want, f"{label}: {got!r} != {want!r}"

    num, string, boolean, null = ({"type": t} for t in ("number", "string", "boolean", "null"))
    eq(shape(1), num, "int")
    eq(shape(1.5), num, "float")
    eq(shape(True), boolean, "bool is not number")
    eq(shape("x"), string, "string")
    eq(shape(None), null, "null")
    eq(shape([]), {"type": "array", "items": None}, "empty array")
    eq(shape({"b": 1, "a": "x"}),
       {"type": "object", "properties": {"a": string, "b": num}}, "object")
    eq(list(shape({"b": 1, "a": 2})["properties"]), ["a", "b"], "keys sorted")
    # elements merge: union of keys, null adopts the other side, int+float agree
    merged = shape([{"a": 1}, {"a": 2.5, "b": None}, {"b": "s"}])
    eq(merged, {"type": "array", "items": {"type": "object", "properties": {
        "a": num, "b": string}}}, "array merge")
    eq(shape([[], [1]]), {"type": "array", "items": {"type": "array", "items": num}},
       "empty inner array adopts sibling")
    eq(shape([None, 1]), {"type": "array", "items": num}, "null+number")
    # conflict is recorded, first by type name wins, and never raises
    conflicts.clear()
    eq(shape([1, "x"]), {"type": "array", "items": num}, "conflict result")
    eq(conflicts, ["[]: number vs string"], "conflict report")
    conflicts.clear()
    # values never leak into the shape
    assert "secret" not in dumps(shape({"k": "secret", "l": ["secret"]}))
    # output is byte-stable
    eq(dumps(shape({"a": [1]})), dumps(shape({"a": [2.0]})), "stable bytes")
    try:
        shape(object())
    except TypeError:
        pass
    else:
        raise AssertionError("unsupported type must raise")
    print("shape.py self-test: ok")


def main(argv):
    strict = "--strict" in argv
    argv = [a for a in argv if a != "--strict"]
    if argv == ["--self-test"]:
        self_test()
        return 0
    if len(argv) > 1 or (argv and argv[0].startswith("-")):
        print(__doc__, file=sys.stderr)
        return 2
    text = open(argv[0], encoding="utf-8").read() if argv else sys.stdin.read()
    sys.stdout.write(dumps(shape(json.loads(text))))
    for c in conflicts:
        print(f"shape.py: conflict {c}", file=sys.stderr)
    return 3 if conflicts and strict else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
