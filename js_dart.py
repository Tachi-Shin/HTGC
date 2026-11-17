"""Lower JavaScript syntax to Dart operations; never evaluate input JavaScript."""

import json
import re
from pathlib import Path
import shutil
import subprocess

from frontend import CompileError


def runtime_source():
    """Inline Dart library parts into the single-file generated runtime."""
    root = Path(__file__).parent / "runtime"
    source = (root / "js_core.dart").read_text(encoding="utf-8")
    parts = re.findall(r"^part '([^']+)';$", source, flags=re.M)
    source = re.sub(r"^part '[^']+';\n", "", source, flags=re.M)
    for part in parts:
        text = (root / part).read_text(encoding="utf-8")
        source += "\n" + re.sub(r"^part of '[^']+';\n", "", text, flags=re.M)
    return source


def quote(value):
    # Escape lone UTF-16 surrogates as well as non-ASCII characters. Test262
    # strings may contain isolated surrogates that cannot be written as UTF-8.
    return json.dumps(value, ensure_ascii=True).replace("$", r"\$")


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
        self.asynchronous = False
        self.temps = []
        self.module_owner = None

    def temp(self):
        name = self.name("tmp")
        self.temps.append(name)
        return name

    def temp_declarations(self):
        return "" if not self.temps else "dynamic " + ", ".join(self.temps) + ";\n"

    @staticmethod
    def has_await(node):
        if isinstance(node, list):
            return any(Compiler.has_await(child) for child in node)
        if not isinstance(node, dict):
            return False
        if node.get("type") in ("FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression"):
            return False
        return node.get("type") == "AwaitExpression" or any(
            Compiler.has_await(child) for child in node.values()
        )

    def async_body(self, code):
        # A return completion must pass through finally before settling a promise.
        return (
            "jAsync((_promise) async {\ntry {\n" + code
            + "\n} on JAsyncReturn catch (_return) {\n_promise.resolve(_return.value);\n"
            "} catch (_error) {\n_promise.reject(jExceptionValue(_error));\n}\n})"
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

    def member(self, node, *, call=False, optional_call=False):
        temp = self.temp()
        obj, key = self.expr(node["object"]), self.key(node)
        test = f"identical({temp} = {obj}, jShortCircuit)"
        if node.get("optional"):
            test += f" || jNullish({temp})"
        value = (f"JCallSite.member({temp}, {key}, optionalCall: {str(optional_call).lower()})"
                 if call else f"jGet({temp}, {key})")
        skipped = "JCallSite(jShortCircuit)" if call else "jShortCircuit"
        return f"({test} ? {skipped} : {value})"

    def property_key(self, node):
        key = node["key"]
        return (quote(key["name"])
                if not node.get("computed") and key["type"] == "Identifier"
                else self.expr(key))

    def bind(self, pattern, value, kind="let"):
        if pattern["type"] == "Identifier":
            if kind == "var":
                return f'{self.scope}.put({quote(pattern["name"])}, {value});'
            return f'{self.scope}.define({quote(pattern["name"])}, {value}, constant: {str(kind == "const").lower()});'
        if pattern["type"] == "AssignmentPattern":
            temp = self.name("default")
            return (f"final {temp} = {value};\n" + self.bind(pattern["left"],
                    f"(identical({temp}, jUndefined) ? {self.expr(pattern['right'])} : {temp})", kind))
        if pattern["type"] == "ObjectPattern":
            temp, keys = self.name("v"), self.name("keys")
            code = f"final {temp} = jRequireCoercible({value});\nfinal {keys} = <Object>[];\n"
            for prop in pattern["properties"]:
                if prop["type"] == "RestElement":
                    code += self.bind(prop["argument"], f"jCopyProperties({temp}, excluding: {keys})", kind) + "\n"
                    continue
                key = self.name("key")
                expression = self.property_key(prop)
                code += f"final {key} = jPropertyKey({expression});\n{keys}.add({key});\n"
                code += self.bind(prop["value"], f"jGet({temp}, {key})", kind) + "\n"
            return code
        if pattern["type"] == "ArrayPattern":
            iterator = self.name("iterator")
            code = f"final {iterator} = jGetIterator({value});\ntry {{\n"
            for element in pattern["elements"]:
                if element is None:
                    code += f"{iterator}.advance();\n"
                elif element["type"] == "RestElement":
                    rest = self.name("rest")
                    code += f"final {rest} = <dynamic>[];\nwhile ({iterator}.advance()) {{ {rest}.add({iterator}.current); }}\n"
                    code += self.bind(element["argument"], rest, kind) + "\n"
                else:
                    code += self.bind(element, f"({iterator}.advance() ? {iterator}.current : jUndefined)", kind) + "\n"
            return code + f"}} catch (_error) {{ {iterator}.close(suppressErrors: _error is! JAsyncReturn); rethrow; }} finally {{ {iterator}.close(); }}\n"
        self.fail(pattern)

    def binding_names(self, pattern):
        kind = pattern["type"]
        if kind == "Identifier":
            yield pattern["name"]
        elif kind == "ObjectPattern":
            for prop in pattern["properties"]:
                if prop["type"] == "Property":
                    yield from self.binding_names(prop["value"])
                elif prop["type"] == "RestElement":
                    yield from self.binding_names(prop["argument"])
                else:
                    self.fail(prop)
        elif kind in ("AssignmentPattern", "RestElement"):
            yield from self.binding_names(pattern["left"] if kind == "AssignmentPattern" else pattern["argument"])
        elif kind == "ArrayPattern":
            for element in pattern["elements"]:
                if element is not None:
                    yield from self.binding_names(element)
        else:
            self.fail(pattern)

    def var_names(self, node):
        if isinstance(node, list):
            for item in node:
                yield from self.var_names(item)
        elif isinstance(node, dict):
            kind = node.get("type")
            if kind in (
                "FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression",
                "ClassDeclaration", "ClassExpression",
            ):
                return
            if kind == "VariableDeclaration" and node["kind"] == "var":
                for declaration in node["declarations"]:
                    yield from self.binding_names(declaration["id"])
            else:
                for child in node.values():
                    yield from self.var_names(child)

    def function(self, node):
        if node.get("generator"):
            from js_generator import compile_generator
            return self.function_metadata(compile_generator(self, node), node)
        old_scope, old_this = self.scope, self.receiver
        old_async, old_temps = self.asynchronous, self.temps
        self.asynchronous, self.temps = node.get("async", False), []
        scope, args, receiver = self.name(), self.name("a"), self.name("this")
        self.scope = scope
        self.receiver = (
            old_this if node["type"] == "ArrowFunctionExpression" else receiver
        )
        body = [f"final {scope} = JScope({old_scope});"]
        for i, param in enumerate(node["params"]):
            value = f"jArg({args}, {i})"
            if param["type"] == "RestElement":
                value = f"{args}.skip({i}).toList()"
                param = param["argument"]
            if param["type"] == "AssignmentPattern":
                value = f'jDefault({value}, () => {self.expr(param["right"])})'
                param = param["left"]
            body.append(self.bind(param, value))
        if node["body"]["type"] == "BlockStatement":
            body.append(self.block_contents(node["body"]["body"], hoist_vars=True))
            if not self.returns(node["body"]):
                body.append("throw JAsyncReturn(jUndefined);" if self.asynchronous else "return jUndefined;")
        else:
            value = self.expr(node["body"])
            body.append(f'throw JAsyncReturn({value});' if self.asynchronous else f'return {value};')
        code = self.temp_declarations() + "\n".join(body)
        result = (
            f"JFunction(({args}, {receiver}) => {self.async_body(code)}, constructible: false)"
            if self.asynchronous else (
                f"JFunction(({args}, {receiver}) {{\n{code}\n}}, constructible: false)"
                if node["type"] == "ArrowFunctionExpression" or node.get("htgc_method") else
                f"jFunction(({args}, {receiver}) {{\n{code}\n}})"
            )
        )
        self.scope, self.receiver = old_scope, old_this
        self.asynchronous, self.temps = old_async, old_temps
        return self.function_metadata(result, node)

    def function_metadata(self, expression, node):
        length = 0
        for param in node['params']:
            if param['type'] in ('AssignmentPattern', 'RestElement'):
                break
            length += 1
        name = (node.get('id') or {}).get('name', '')
        return f'jNamedFunction({expression}, {quote(name)}, {length})'

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
        if node["type"] == "TryStatement":
            finalizer = node.get("finalizer")
            handler = node.get("handler")
            return (finalizer is not None and self.returns(finalizer)) or (
                self.returns(node["block"])
                and (handler is None or self.returns(handler["body"]))
            )
        return False

    def expr(self, n):
        if n is None:
            return "jUndefined"
        t = n["type"]
        if t == "AwaitExpression":
            if not self.asynchronous:
                self.fail(n, "await outside async function/module")
            return f'(await jAwait({self.expr(n["argument"])}))'
        if t == "ImportExpression":
            if self.module_owner is None:
                self.fail(n, "dynamic import requires a compiled module graph")
            if n.get("options") is not None:
                self.fail(n, "import attributes")
            return (
                f'{self.scope}.modules(htgcModules).importModule('
                f'{quote(self.module_owner)}, {self.expr(n["source"])})'
            )
        if t == "ClassExpression":
            return self.class_expression(n)
        if t == "Identifier":
            return f'{self.scope}.get({quote(n["name"])})'
        if t == "ThisExpression":
            return self.receiver
        if t == "Literal":
            if "regex" in n:
                regex = n["regex"]
                lowered = f', lowered: {quote(regex["lowered"])}' if "lowered" in regex else ""
                return f'JRegex({quote(regex["pattern"])}, {quote(regex["flags"])}{lowered})'
            value = n.get("value")
            if "bigint" in n:
                digits = n["bigint"].replace("_", "")
                radix = {"0x": 16, "0o": 8, "0b": 2}.get(digits[:2].lower())
                return (f'BigInt.parse({quote(digits[2:])}, radix: {radix})'
                        if radix else f'BigInt.parse({quote(digits)})')
            if type(value) in (int, float):
                # ECMAScript Number is binary64, including integral literals.
                return repr(float(value))
            if value is None and (n.get("raw", "")[0:1].isdigit() or n.get("raw", "").startswith(".")):
                return "double.infinity"
            return quote(value) if isinstance(value, str) else json.dumps(value)
        if t == "ArrayExpression":
            parts = []
            for item in n["elements"]:
                parts.append(
                    "...jIterable(" + self.expr(item["argument"]) + ")"
                    if item and item["type"] == "SpreadElement"
                    else self.expr(item) if item is not None else "_jHole"
                )
            return "<dynamic>[" + ", ".join(parts) + "]"
        if t == "ObjectExpression":
            parts = []
            for p in n["properties"]:
                if p["type"] == "SpreadElement":
                    parts.append("...jObjectSpread(" + self.expr(p["argument"]) + ")")
                    continue
                key = self.property_key(p)
                kind = p.get("kind", "init")
                if not p.get("computed") and not p.get("method") and not p.get("shorthand") and kind == "init" and p["key"].get("name", p["key"].get("value")) == "__proto__":
                    kind = "prototype"
                parts.append(f'({quote(kind)}, jPropertyKey({key}), {self.expr(p["value"])})')
            return "jObjectLiteral([" + ", ".join(parts) + "])"
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
            return self.member(n)
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
            if "htgcLoweredRegExp" in n:
                return self.precompiled_regexp(n, self.expr(callee), args)
            if t == "NewExpression":
                return f"jNew({self.expr(callee)}, {args})"
            if callee["type"] == "MemberExpression":
                callsite = self.member(callee, call=True, optional_call=n.get("optional", False))
            else:
                callsite = f'JCallSite({self.expr(callee)}, optional: {optional})'
            if n.get("optional") or callee.get("optional") or callee["type"] == "MemberExpression":
                temp = self.temp()
                return f'(({temp} = {callsite}).skipped ? jShortCircuit : {temp}.call({args}))'
            return f"jCall({self.expr(callee)}, {args}, optional: {optional})"
        if t == "UnaryExpression":
            if n["operator"] == "delete" and n["argument"]["type"] == "MemberExpression":
                target = n["argument"]
                return f'jDelete({self.expr(target["object"])}, {self.key(target)}, strict: true)'
            return f'jUnary({quote(n["operator"])}, {self.expr(n["argument"])})'
        if t == "BinaryExpression":
            return f'jBinary({quote(n["operator"])}, {self.expr(n["left"])}, {self.expr(n["right"])})'
        if t == "LogicalExpression":
            if self.has_await(n["right"]):
                temp = self.temp()
                left, right = self.expr(n["left"]), self.expr(n["right"])
                test = f'jNullish({temp} = {left})' if n["operator"] == "??" else f'jTruthy({temp} = {left})'
                yes, no = (temp, right) if n["operator"] == "||" else (right, temp)
                return f'({test} ? {yes} : {no})'
            return f'jLogical({quote(n["operator"])}, {self.expr(n["left"])}, () => {self.expr(n["right"])})'
        if t == "ConditionalExpression":
            return f'(jTruthy({self.expr(n["test"])}) ? {self.expr(n["consequent"])} : {self.expr(n["alternate"])})'
        if t == "AssignmentExpression":
            if self.has_await(n["right"]):
                temp = self.temp()
                return (
                    f'(({temp} = JAssignment({self.ref(n["left"])}, {quote(n["operator"])})).skip'
                    f' ? {temp}.left : {temp}.assign({self.expr(n["right"])}))'
                )
            return f'jAssign({self.ref(n["left"])}, {quote(n["operator"])}, () => {self.expr(n["right"])})'
        if t == "UpdateExpression":
            return f'jUpdate({self.ref(n["argument"])}, {1 if n["operator"]=="++" else -1}, {str(n["prefix"]).lower()})'
        if t == "SequenceExpression":
            return "<dynamic>[" + ", ".join(self.expr(x) for x in n["expressions"]) + "].last"
        self.fail(n)

    def block_contents(self, nodes, *, hoist_vars=False):
        # Function declarations are initialized before the surrounding statements.
        code = [self.stmt(n) for n in nodes if n["type"] == "FunctionDeclaration"]
        if hoist_vars:
            code.extend(
                f"{self.scope}.declareVar({quote(name)});"
                for name in dict.fromkeys(self.var_names(nodes))
            )
        code.extend(self.stmt(n) for n in nodes if n["type"] != "FunctionDeclaration")
        return "\n".join(code)

    def switch(self, node):
        cases = node["cases"]
        if not cases:
            return self.expr(node["discriminant"]) + ";"
        value, selected = self.name("value"), self.name("case")
        discriminant = self.expr(node["discriminant"])
        parent = self.scope
        self.scope = self.name()
        labels = [self.name("case") for _ in cases]
        def terminates(body):
            return bool(body) and (
                body[-1]["type"] in ("BreakStatement", "ContinueStatement")
                or self.returns(body[-1])
            )

        falls_through = [not terminates(case["consequent"]) for case in cases]
        code = [
            "{",
            f"final {value} = {discriminant};",
            f"final {self.scope} = JScope({parent});",
        ]
        code.extend(
            self.stmt(stmt)
            for case in cases
            for stmt in case["consequent"]
            if stmt["type"] == "FunctionDeclaration"
        )
        default = next((i for i, case in enumerate(cases) if case["test"] is None), -1)
        choices = [
            f'jBinary("===", {value}, {self.expr(case["test"])}) == true ? {i} : '
            for i, case in enumerate(cases)
            if case["test"] is not None
        ]
        code.extend([
            f"final {selected} = {''.join(choices)}{default};",
            f"switch ({selected}) {{",
        ])
        for i, case in enumerate(cases):
            label = f"{labels[i]}: " if i > 0 and falls_through[i - 1] else ""
            code.append(f"{label}case {i}:")
            body = case["consequent"]
            code.extend(
                self.stmt(stmt) for stmt in body
                if stmt["type"] != "FunctionDeclaration"
            )
            if i + 1 < len(cases) and falls_through[i]:
                code.append(f"continue {labels[i + 1]};")
            elif falls_through[i]:
                code.append("break;")
        self.scope = parent
        return "\n".join([*code, "}", "}"])

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
                if n["kind"] != "var" or d.get("init") is not None
            )
        if t == "FunctionDeclaration":
            return self.bind(n["id"], self.function(n))
        if t == "BlockStatement":
            if not any(
                child["type"] in ("ClassDeclaration", "FunctionDeclaration")
                or child["type"] == "VariableDeclaration" and child["kind"] != "var"
                for child in n["body"]
            ):
                return "{\n" + self.block_contents(n["body"]) + "\n}"
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
            if self.asynchronous:
                return "throw JAsyncReturn(" + self.expr(n.get("argument")) + ");"
            return "return " + self.expr(n.get("argument")) + ";"
        if t == "IfStatement":
            return (
                f'if (jTruthy({self.expr(n["test"])})) {self.stmt(n["consequent"])}'
                + (" else " + self.stmt(n["alternate"]) if n.get("alternate") else "")
            )
        if t == "ForOfStatement":
            asynchronous = n.get("await", False)
            if asynchronous and not self.asynchronous:
                self.fail(n, 'for await outside async function/module')
            iterator = self.name("item")
            source = self.expr(n["right"])
            parent = self.scope
            self.scope = self.name()
            left = n["left"]
            if left["type"] == "VariableDeclaration":
                init = self.bind(left["declarations"][0]["id"], iterator, left["kind"])
            else:
                init = f'jAssign({self.ref(left)}, "=", () => {iterator});'
            record = self.name("iterator")
            caught = self.name("error")
            factory = 'jGetAsyncIterator' if asynchronous else 'jGetIterator'
            def wait(expression):
                return f'(await jAwait({expression}))' if asynchronous else expression
            body = (f'{{ final {record} = {factory}({source});\ntry {{\n'
                    f'while ({wait(f"{record}.advance()")}) {{\nfinal {iterator} = {record}.current;\n'
                    f'final {self.scope} = JScope({parent});\n{init}\n{self.stmt(n["body"])}\n}}'
                    f'\n}} catch ({caught}) {{\n{wait(f"{record}.close(suppressErrors: {caught} is! JAsyncReturn)")};\nrethrow;\n}}'
                    f' finally {{ {wait(f"{record}.close()")}; }}\n}}')
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
        if t == "DoWhileStatement":
            return f'do {{\n{self.stmt(n["body"])}\n}} while (jTruthy({self.expr(n["test"])}));'
        if t == "SwitchStatement":
            return self.switch(n)
        if t == "TryStatement":
            code = "try " + self.stmt(n["block"])
            handler = n.get("handler")
            if handler is not None and handler["param"] is None and not self.asynchronous:
                code += " on Object " + self.stmt(handler["body"])
            elif handler is not None:
                caught = self.name("caught")
                parent = self.scope
                self.scope = self.name()
                code += f" catch ({caught}) {{\nfinal {self.scope} = JScope({parent});\n"
                if self.asynchronous:
                    code += f"if ({caught} is JAsyncReturn) rethrow;\n"
                value = f"{caught} is JThrown ? {caught}.value : {caught}"
                if handler["param"] is not None:
                    code += self.bind(handler["param"], value) + "\n"
                code += self.stmt(handler["body"]) + "\n}"
                self.scope = parent
            if n.get("finalizer") is not None:
                code += " finally " + self.stmt(n["finalizer"])
            return code
        if t in ("BreakStatement", "ContinueStatement"):
            if n.get("label"):
                self.fail(n)
            return ("break" if t == "BreakStatement" else "continue") + ";"
        if t == "ClassDeclaration":
            return self.bind(n["id"], self.class_expression(n))
        if t == "ThrowStatement":
            return "throw JThrown(" + self.expr(n["argument"]) + ");"
        self.fail(n)

    def precompiled_regexp(self, node, callee, args):
        constructing = str(node["type"] == "NewExpression").lower()
        return (f'jCallPrecompiledRegExp({callee}, {args}, '
                f'{quote(node["htgcLoweredRegExp"])}, constructing: {constructing})')

    def class_expression(self, node):
        for method in node["body"]["body"]:
            if (method["type"] != "MethodDefinition" or method["kind"] == "constructor"
                    or method["key"]["type"] == "PrivateIdentifier"):
                self.fail(method, "class fields and explicit constructors")
        if self.has_await(node):
            self.fail(node, "await in class heritage or computed keys")
        name = (node.get("id") or {}).get("name", "")
        parent = self.scope
        inner, constructor, base = self.name("classScope"), self.name("class"), self.name("base")
        self.scope = inner
        try:
            superclass = node.get("superClass")
            base_expression = "null" if superclass is None else self.expr(superclass)
            code = [
                f"final {inner} = JScope({parent});",
                *([f"{inner}.reserve({quote(name)});"] if name else []),
                f"final {base} = {base_expression};",
                f'final {constructor} = jDefaultClass({quote(name)}, {base}, derived: {str(superclass is not None).lower()});',
            ]
            for method in node["body"]["body"]:
                key = self.property_key(method)
                function = self.function({**method["value"], "htgc_method": True})
                mode = "init" if method["kind"] == "method" else method["kind"]
                static = str(method["static"]).lower()
                code.append(f"jDefineClassMethod({constructor}, {static}, {quote(mode)}, jPropertyKey({key}), {function});")
            if name:
                code.append(f"{inner}.define({quote(name)}, {constructor}, constant: true);")
            code.append(f"return {constructor};")
            return "(() {\n" + "\n".join(code) + "\n})()"
        finally:
            self.scope = parent

    def compile(self, ast, name):
        body = self.block_contents(ast["body"], hoist_vars=True)
        return (
            f'// JavaScript source: {self.path.replace(chr(10)," ")}\nvoid {name}(JScope scope) {{\n'
            + self.temp_declarations() + body
            + "\n}\n"
        )


def compile_script(source, path, name="htgcScript"):
    return Compiler(path).compile(parse(source, path), name)
