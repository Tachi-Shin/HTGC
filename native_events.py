"""Parse and emit native function calls in HTML event attributes."""

import math
import re

from c_source import c_string
from frontend import CompileError
from js_dart import parse, quote


def parse_handler(source, path, attribute):
    def unsupported():
        return CompileError(f"{path}: {attribute}: 未対応の関数呼び出し {source!r}")

    def identifier(node):
        if node["type"] == "Identifier" and re.fullmatch(
            r"[A-Za-z_][A-Za-z_0-9]*", node["name"]
        ):
            return node["name"]
        raise unsupported()

    def member_path(node):
        if node["type"] == "ThisExpression":
            return "this"
        if node["type"] == "Identifier":
            return node["name"]
        if node["type"] == "MemberExpression" and not node["computed"]:
            return f"{member_path(node['object'])}.{identifier(node['property'])}"
        return ""

    def argument(node):
        kind = node["type"]
        if kind == "Literal" and "value" in node and not {"regex", "bigint"} & node.keys():
            value = node["value"]
            if value is None and node["raw"] != "null":
                raise unsupported()
            if type(value) is float and not math.isfinite(value):
                raise unsupported()
            if type(value) is int and abs(value) > (1 << 53) - 1:
                raise unsupported()
            spelling = node["raw"].lower()
            decimal = not spelling.startswith(("0x", "0o", "0b"))
            if type(value) is int and decimal and ("." in spelling or "e" in spelling):
                value = float(value)
            return ("literal", value)
        if kind == "UnaryExpression" and node["operator"] in {"+", "-"}:
            operand = argument(node["argument"])
            if operand[0] == "literal" and type(operand[1]) in {int, float}:
                return ("literal", -operand[1] if node["operator"] == "-" else operand[1])
        if kind == "CallExpression":
            return call(node)
        if attribute == "oninput" and member_path(node) in {"text", "this.value", "event.target.value"}:
            return ("text",)
        if kind == "Identifier":
            return ("value", identifier(node))
        raise unsupported()

    def call(node):
        if node["type"] != "CallExpression" or node.get("optional"):
            raise unsupported()
        return ("call", identifier(node["callee"]), tuple(map(argument, node["arguments"])))

    statements = parse(source, path)["body"]
    if len(statements) != 1 or statements[0]["type"] != "ExpressionStatement":
        raise unsupported()
    return call(statements[0]["expression"])


def emit_handler(expression, *, dart, text_parameter):
    kind, *parts = expression
    prefix = "handlers." if dart else ""
    if kind == "text":
        return text_parameter
    if kind == "value":
        return prefix + parts[0]
    if kind == "call":
        name, arguments = parts
        args = ", ".join(
            emit_handler(arg, dart=dart, text_parameter=text_parameter)
            for arg in arguments
        )
        return f"{prefix}{name}({args})"
    value = parts[0]
    if isinstance(value, str):
        return quote(value) if dart else c_string(value)
    if value is None:
        return "null" if dart else "NULL"
    if isinstance(value, bool):
        return str(value).lower()
    return repr(value)
