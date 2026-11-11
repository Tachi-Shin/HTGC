"""Lower JavaScript syntax to Dart operations; never evaluate input JavaScript."""

import json
from pathlib import Path
import shutil
import subprocess

from frontend import CompileError


def quote(value):
    return json.dumps(value, ensure_ascii=False).replace("$", r"\$")


def parse(source, path):
    node = shutil.which("node")
    parser = Path(__file__).parent / "javascript" / "parse.cjs"
    if not node:
        raise CompileError("JavaScriptの構文解析にはNode.jsが必要です")
    result = subprocess.run(
        [node, str(parser)], input=source, encoding="utf-8", capture_output=True
    )
    if result.returncode:
        raise CompileError(
            f"{path}: JavaScript解析失敗: {result.stderr.strip()} (npm --prefix javascript ci)"
        )
    return json.loads(result.stdout)


class Compiler:
    def __init__(self, path):
        self.path, self.serial, self.scope, self.receiver = (
            str(path),
            0,
            "scope",
            "jUndefined",
        )

    def name(self, prefix="s"):
        self.serial += 1
        return f"_{prefix}{self.serial}"

    def fail(self, node, description=None):
        line = node.get("loc", {}).get("start", {}).get("line", "?")
        raise CompileError(
            f'{self.path}:{line}: DartへのJavaScript変換は未対応: {description or node["type"]}'
        )

    def ref(self, node):
        if node["type"] == "Identifier":
            return f'JRef.scope({self.scope}, {quote(node["name"])})'
        if node["type"] == "MemberExpression":
            return f'JRef.member({self.expr(node["object"])}, {self.key(node)})'
        self.fail(node, "assignment target")

    def key(self, node):
        return (
            self.expr(node["property"])
            if node.get("computed")
            else quote(node["property"]["name"])
        )

    def bind(self, pattern, value, kind="let"):
        if pattern["type"] == "Identifier":
            return f'{self.scope}.define({quote(pattern["name"])}, {value}, constant: {str(kind == "const").lower()});'
        if pattern["type"] == "ObjectPattern":
            temp = self.name("v")
            code = f"final {temp} = {value};\n"
            for prop in pattern["properties"]:
                if prop["type"] != "Property":
                    self.fail(prop)
                key = prop["key"].get("name", prop["key"].get("value"))
                code += (
                    self.bind(prop["value"], f"jGet({temp}, {quote(key)})", kind) + "\n"
                )
            return code
        if pattern["type"] == "ArrayPattern":
            temp = self.name("v")
            return f"final {temp} = {value};\n" + "\n".join(
                self.bind(p, f"jGet({temp}, {i})", kind)
                for i, p in enumerate(pattern["elements"])
                if p
            )
        self.fail(pattern)

    def function(self, node):
        if node.get("async") or node.get("generator"):
            self.fail(node, "async/generator function")
        old_scope, old_this = self.scope, self.receiver
        scope, args, receiver = self.name(), self.name("a"), self.name("this")
        self.scope = scope
        self.receiver = (
            old_this if node["type"] == "ArrowFunctionExpression" else receiver
        )
        body = [f"final {scope} = JScope({old_scope});"]
        for i, param in enumerate(node["params"]):
            value = f"jArg({args}, {i})"
            if param["type"] == "AssignmentPattern":
                value = f'jDefault({value}, () => {self.expr(param["right"])})'
                param = param["left"]
            body.append(self.bind(param, value))
        if node["body"]["type"] == "BlockStatement":
            body.append(self.block_contents(node["body"]["body"]))
            if not self.returns(node["body"]):
                body.append("return jUndefined;")
        else:
            body.append(f'return {self.expr(node["body"])};')
        self.scope, self.receiver = old_scope, old_this
        return f"JFunction(({args}, {receiver}) {{\n" + "\n".join(body) + "\n})"

    def returns(self, node):
        if node["type"] in ("ReturnStatement", "ThrowStatement"):
            return True
        if node["type"] == "BlockStatement":
            return bool(node["body"]) and self.returns(node["body"][-1])
        if node["type"] == "IfStatement":
            return (
                bool(node.get("alternate"))
                and self.returns(node["consequent"])
                and self.returns(node["alternate"])
            )
        return False

    def expr(self, n):
        if n is None:
            return "jUndefined"
        t = n["type"]
        if t == "Identifier":
            return f'{self.scope}.get({quote(n["name"])})'
        if t == "ThisExpression":
            return self.receiver
        if t == "Literal":
            if "regex" in n:
                return f'JRegex({quote(n["regex"]["pattern"])}, {quote(n["regex"]["flags"])})'
            value = n.get("value")
            return quote(value) if isinstance(value, str) else json.dumps(value)
        if t == "ArrayExpression":
            parts = []
            for item in n["elements"]:
                parts.append(
                    "...jIterable(" + self.expr(item["argument"]) + ")"
                    if item and item["type"] == "SpreadElement"
                    else self.expr(item)
                )
            return "<dynamic>[" + ", ".join(parts) + "]"
        if t == "ObjectExpression":
            parts = []
            for p in n["properties"]:
                if p["type"] == "SpreadElement":
                    parts.append("...jProperties(" + self.expr(p["argument"]) + ")")
                    continue
                key = (
                    self.expr(p["key"])
                    if p.get("computed")
                    else quote(p["key"].get("name", p["key"].get("value")))
                )
                parts.append(f'jString({key}): {self.expr(p["value"])}')
            return "JObject({" + ", ".join(parts) + "})"
        if t in ("FunctionExpression", "ArrowFunctionExpression"):
            return self.function(n)
        if t == "TemplateLiteral":
            parts = []
            for i, q in enumerate(n["quasis"]):
                parts.append(quote(q["value"]["cooked"]))
                if i < len(n["expressions"]):
                    parts.append(f'jString({self.expr(n["expressions"][i])})')
            return "(" + " + ".join(parts) + ")"
        if t == "MemberExpression":
            return f'jGet({self.expr(n["object"])}, {self.key(n)}, optional: {str(n.get("optional",False)).lower()})'
        if t == "ChainExpression":
            return f'jEndChain({self.expr(n["expression"])})'
        if t in ("CallExpression", "NewExpression"):
            args = (
                "<dynamic>["
                + ", ".join(
                    (
                        "...jIterable(" + self.expr(x["argument"]) + ")"
                        if x["type"] == "SpreadElement"
                        else self.expr(x)
                    )
                    for x in n["arguments"]
                )
                + "]"
            )
            callee = n["callee"]
            optional = str(n.get("optional", False)).lower()
            if t == "NewExpression":
                return f"jNew({self.expr(callee)}, {args})"
            if callee["type"] == "MemberExpression":
                return f'jInvoke({self.expr(callee["object"])}, {self.key(callee)}, {args}, optionalObject: {str(callee.get("optional",False)).lower()}, optionalCall: {optional})'
            return f"jCall({self.expr(callee)}, {args}, optional: {optional})"
        if t == "UnaryExpression":
            return f'jUnary({quote(n["operator"])}, {self.expr(n["argument"])})'
        if t == "BinaryExpression":
            return f'jBinary({quote(n["operator"])}, {self.expr(n["left"])}, {self.expr(n["right"])})'
        if t == "LogicalExpression":
            return f'jLogical({quote(n["operator"])}, {self.expr(n["left"])}, () => {self.expr(n["right"])})'
        if t == "ConditionalExpression":
            return f'(jTruthy({self.expr(n["test"])}) ? {self.expr(n["consequent"])} : {self.expr(n["alternate"])})'
        if t == "AssignmentExpression":
            return f'jAssign({self.ref(n["left"])}, {quote(n["operator"])}, () => {self.expr(n["right"])})'
        if t == "UpdateExpression":
            return f'jUpdate({self.ref(n["argument"])}, {1 if n["operator"]=="++" else -1}, {str(n["prefix"]).lower()})'
        if t == "SequenceExpression":
            return (
                "(() { "
                + " ".join(self.expr(x) + ";" for x in n["expressions"][:-1])
                + " return "
                + self.expr(n["expressions"][-1])
                + "; })()"
            )
        self.fail(n)

    def block_contents(self, nodes):
        # Function declarations are initialized before the surrounding statements.
        return (
            "\n".join(self.stmt(n) for n in nodes if n["type"] == "FunctionDeclaration")
            + "\n"
            + "\n".join(
                self.stmt(n) for n in nodes if n["type"] != "FunctionDeclaration"
            )
        )

    def stmt(self, n):
        t = n["type"]
        if t == "ExpressionStatement":
            return self.expr(n["expression"]) + ";"
        if t == "EmptyStatement":
            return ";"
        if t == "VariableDeclaration":
            return "\n".join(
                self.bind(d["id"], self.expr(d.get("init")), n["kind"])
                for d in n["declarations"]
            )
        if t == "FunctionDeclaration":
            return self.bind(n["id"], self.function(n))
        if t == "BlockStatement":
            parent = self.scope
            self.scope = self.name()
            body = (
                f"{{\nfinal {self.scope} = JScope({parent});\n"
                + self.block_contents(n["body"])
                + "\n}"
            )
            self.scope = parent
            return body
        if t == "ReturnStatement":
            return "return " + self.expr(n.get("argument")) + ";"
        if t == "IfStatement":
            return (
                f'if (jTruthy({self.expr(n["test"])})) {self.stmt(n["consequent"])}'
                + (" else " + self.stmt(n["alternate"]) if n.get("alternate") else "")
            )
        if t == "ForOfStatement":
            if n.get("await"):
                self.fail(n)
            iterator = self.name("item")
            source = self.expr(n["right"])
            parent = self.scope
            self.scope = self.name()
            left = n["left"]
            if left["type"] == "VariableDeclaration":
                init = self.bind(left["declarations"][0]["id"], iterator, left["kind"])
            else:
                init = f'jAssign({self.ref(left)}, "=", () => {iterator});'
            body = f'for (final {iterator} in jIterable({source})) {{\nfinal {self.scope} = JScope({parent});\n{init}\n{self.stmt(n["body"])}\n}}'
            self.scope = parent
            return body
        if t == "ForStatement":
            parent = self.scope
            self.scope = self.name()
            init = (
                self.stmt(n["init"])
                if n.get("init") and n["init"]["type"] == "VariableDeclaration"
                else self.expr(n.get("init")) + ";"
            )
            condition = (
                "true" if not n.get("test") else "jTruthy(" + self.expr(n["test"]) + ")"
            )
            code = (
                "{\n"
                + f"final {self.scope} = JScope({parent});\n"
                + init
                + "\nfor (; "
                + condition
                + "; "
                + self.expr(n.get("update"))
                + ") "
                + self.stmt(n["body"])
                + "\n}"
            )
            self.scope = parent
            return code
        if t == "WhileStatement":
            return (
                "while (jTruthy(" + self.expr(n["test"]) + ")) " + self.stmt(n["body"])
            )
        if t in ("BreakStatement", "ContinueStatement"):
            if n.get("label"):
                self.fail(n)
            return ("break" if t == "BreakStatement" else "continue") + ";"
        if t == "ClassDeclaration":
            methods = []
            for m in n["body"]["body"]:
                if (
                    m["type"] != "MethodDefinition"
                    or m["kind"] != "method"
                    or m["static"]
                    or m["computed"]
                ):
                    self.fail(m)
                methods.append(
                    quote(m["key"]["name"]) + ": " + self.function(m["value"])
                )
            return self.bind(
                n["id"],
                "JClass("
                + self.expr(n.get("superClass"))
                + ", {"
                + ", ".join(methods)
                + "})",
            )
        if t == "ThrowStatement":
            return "throw " + self.expr(n["argument"]) + ";"
        self.fail(n)

    def compile(self, ast, name):
        return (
            f'// JavaScript source: {self.path.replace(chr(10)," ")}\nvoid {name}(JScope scope) {{\n'
            + self.block_contents(ast["body"])
            + "\n}\n"
        )


def compile_script(source, path, name="htgcScript"):
    return Compiler(path).compile(parse(source, path), name)
