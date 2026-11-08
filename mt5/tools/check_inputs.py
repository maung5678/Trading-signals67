#!/usr/bin/env python3
"""Check that the EA passes the indicator inputs in the right order.

The EA creates the embedded indicator with IndicatorCreate(), which takes the
indicator inputs BY POSITION. A missing, extra or swapped parameter silently
shifts every following value, so run this after changing the inputs of either
file:

    python3 mt5/tools/check_inputs.py

Checks:
  1. BuildIndicatorParams() in the EA lists every non-color indicator input in
     the indicator's order, with a matching MQL5 parameter type.
  2. Inputs that the EA declares under the same name have the same type and
     default value as in the indicator.
  3. Enums declared in both files are identical.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INDICATOR = ROOT / "Indicators" / "ST_TP_SL.mq5"
EA = ROOT / "Experts" / "ST_TP_SL_EA.mq5"

INPUT_RE = re.compile(r"^\s*input\s+(?!group\b)(\w+)\s+(\w+)\s*=\s*([^;]+);", re.M)
PARAM_RE = re.compile(r"^[ \t]*Param(Str|Int|Dbl|Bool)\(([^)]*)\);[ \t]*(?://[ \t]*(\w+))?", re.M)
ENUM_RE = re.compile(r"enum\s+(\w+)\s*\{(.*?)\};", re.S)


def read(path):
    return path.read_text(encoding="utf-8-sig")


def inputs(text):
    return [(m.group(2), m.group(1), m.group(3).strip()) for m in INPUT_RE.finditer(text)]


def expected_kind(mql_type):
    if mql_type == "double":
        return "Dbl"
    if mql_type == "bool":
        return "Bool"
    if mql_type == "string":
        return "Str"
    if mql_type in ("int", "long", "uint", "ulong") or mql_type.startswith("ENUM_"):
        return "Int"
    return None


def enums(text):
    return {m.group(1): re.sub(r"\s+", " ", m.group(2)).strip() for m in ENUM_RE.finditer(text)}


def main():
    ind_text, ea_text = read(INDICATOR), read(EA)
    errors = []

    ind_inputs = [i for i in inputs(ind_text) if i[1] != "color"]
    build = ea_text[ea_text.index("void BuildIndicatorParams("):]
    build = build[: build.index("\n  }\n")]
    params = PARAM_RE.findall(build)
    if not params or params[0][0] != "Str":
        errors.append("BuildIndicatorParams() must start with ParamStr(IND_PATH)")
    params = params[1:]

    if len(params) != len(ind_inputs):
        errors.append("EA passes %d parameters, indicator has %d non-color inputs" % (len(params), len(ind_inputs)))
    for pos, ((kind, arg, comment), (name, mql_type, _)) in enumerate(zip(params, ind_inputs), 1):
        passed = arg.strip() if arg.strip().startswith("Inp") else comment
        if passed != name:
            errors.append("parameter %d: EA passes %r, indicator expects %r" % (pos, passed or arg, name))
        want = expected_kind(mql_type)
        if want != kind:
            errors.append("parameter %d (%s): EA uses Param%s, indicator type %s needs Param%s" % (pos, name, kind, mql_type, want))

    ea_inputs = {n: (t, d) for n, t, d in inputs(ea_text)}
    for name, mql_type, default in ind_inputs:
        if name in ea_inputs:
            ea_type, ea_default = ea_inputs[name]
            if ea_type != mql_type:
                errors.append("input %s: type %s in EA, %s in indicator" % (name, ea_type, mql_type))
            if ea_default != default:
                errors.append("input %s: default %s in EA, %s in indicator" % (name, ea_default, default))

    ind_enums, ea_enums = enums(ind_text), enums(ea_text)
    for name in set(ind_enums) & set(ea_enums):
        if ind_enums[name] != ea_enums[name]:
            errors.append("enum %s differs between the files" % name)

    if errors:
        print("FAILED")
        for e in errors:
            print("  - " + e)
        return 1
    print("OK: %d indicator parameters in the right order and type" % len(params))
    return 0


if __name__ == "__main__":
    sys.exit(main())
