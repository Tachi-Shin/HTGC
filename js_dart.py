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
        self.new_target = "jUndefined"
        self.home = None
        self.construction = None
        self.private_names = {}
        self.temps = []
        self.module_owner = None
        self.script_name = ""

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
            if node["property"]["type"] == "PrivateIdentifier":
                return f'{self.private_name(node["property"])}.reference({self.expr(node["object"])})'
            if node["object"]["type"] == "Super":
                return self.super_reference(node)
            return f'JRef.member({self.expr(node["object"])}, {self.key(node)})'
        self.fail(node, "assignment target")

    def key(self, node):
        return (
            self.expr(node["property"])
            if node.get("computed")
            else quote(node["property"]["name"])
        )

    def private_name(self, node):
        name = self.private_names.get(node["name"])
        if name is None:
            self.fail(node, "undeclared private identifier")
        return name

    def super_reference(self, node):
        if self.home is None:
            self.fail(node, "super outside a class method")
        return f'jSuperReference({self.receiver}, {self.home}, {self.key(node)})'

    def member(self, node, *, call=False, optional_call=False):
        if node["object"]["type"] == "Super":
            if not call:
                return f'{self.super_reference(node)}.read()'
            if self.home is None:
                self.fail(node, "super outside a class method")
            return f'jSuperCallSite({self.receiver}, {self.home}, {self.key(node)}, optional: {str(optional_call).lower()})'
        temp = self.temp()
        obj, key = self.expr(node["object"]), self.key(node)
        test = f"identical({temp} = {obj}, jShortCircuit)"
        if node.get("optional"):
            test += f" || jNullish({temp})"
        if node["property"]["type"] == "PrivateIdentifier":
            private = self.private_name(node["property"])
            value = (f'{private}.callSite({temp}, optional: {str(optional_call).lower()})'
                     if call else f'{private}.read({temp})')
        else:
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
        if kind == "assign" and pattern["type"] in ("Identifier", "MemberExpression"):
            return f'{self.ref(pattern)}.write({value});'
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
        named_expression = node["type"] == "FunctionExpression" and node.get("id") is not None
        if named_expression:
            parent = self.scope
            self.scope = self.name("named")
            name = quote(node["id"]["name"])
            scope = self.scope
            try:
                result = self.function_value(node)
            finally:
                self.scope = parent
            return (f'(() {{ final {scope} = JScope({parent}); {scope}.reserve({name}); '
                    f'return {scope}.define({name}, {result}, constant: true); }})()')
        return self.function_value(node)

    def function_value(self, node):
        if node.get("generator"):
            from js_generator import compile_generator
            return self.function_metadata(compile_generator(self, node), node)
        old_scope, old_this, old_target = self.scope, self.receiver, self.new_target
        old_home, old_construction = self.home, self.construction
        old_async, old_temps = self.asynchronous, self.temps
        self.asynchronous, self.temps = node.get("async", False), []
        scope, args, receiver = self.name(), self.name("a"), self.name("this")
        self.scope = scope
        self.receiver = (
            old_this if node["type"] == "ArrowFunctionExpression" else receiver
        )
        arrow = node["type"] == "ArrowFunctionExpression"
        constructible = not arrow and not self.asynchronous and not node.get("htgc_method")
        self.new_target = old_target if arrow else self.name("newTarget") if constructible else "jUndefined"
        self.home = old_home if arrow else node.get("htgc_home")
        self.construction = old_construction if arrow else None
        if node.get("htgc_constructor"):
            self.construction = receiver
            self.receiver = f'{receiver}.thisValue'
            self.new_target = f'{receiver}.newTarget'
        body = [f"final {scope} = JScope({old_scope});"]
        if not arrow:
            body.append(f'{scope}.define("arguments", jArgumentsObject({args}));')
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
                f"jFunction(({args}, {receiver}, {self.new_target}) {{\n{code}\n}})"
            )
        )
        self.scope, self.receiver, self.new_target = old_scope, old_this, old_target
        self.home, self.construction = old_home, old_construction
        self.asynchronous, self.temps = old_async, old_temps
        return self.function_metadata(result, node)

    def function_metadata(self, expression, node):
        length = 0
        for param in node['params']:
            if param['type'] in ('AssignmentPattern', 'RestElement'):
                break
            length += 1
        name = (node.get('id') or {}).get('name', '')
        source = f', source: {quote(node["htgcSource"])}' if "htgcSource" in node else ""
        return f'jNamedFunction({expression}, {quote(name)}, {length}{source})'

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
        if t == "MetaProperty" and n["meta"]["name"] == "new":
            return self.new_target
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
        if t == "TaggedTemplateExpression":
            tag = n["tag"]
            callee = self.member(tag, call=True) if tag["type"] == "MemberExpression" else f'JCallSite({self.expr(tag)})'
            args = [self.template_object(n), *(self.expr(value) for value in n["quasi"]["expressions"])]
            return f'{callee}.call(<dynamic>[{", ".join(args)}])'
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
            if callee["type"] == "Super":
                if self.construction is None:
                    self.fail(n, "super() outside a class constructor")
                return f'{self.construction}.callSuper({args})'
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
            if n["left"]["type"] == "PrivateIdentifier" and n["operator"] == "in":
                return f'{self.private_name(n["left"])}.has({self.expr(n["right"])})'
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
            if n["left"]["type"] in ("ArrayPattern", "ObjectPattern"):
                value = self.name("rhs")
                argument = self.expr(n["right"])
                assignment = self.bind(n["left"], value, "assign")
                asynchronous = self.has_await(n["left"])
                call = f'(({value}) {"async " if asynchronous else ""}{{\n{assignment}\nreturn {value};\n}})({argument})'
                return f'(await {call})' if asynchronous else call
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

    def template_object(self, node):
        quasis = node["quasi"]["quasis"]
        cooked = [quote(part["value"]["cooked"]) if part["value"]["cooked"] is not None else "jUndefined"
                  for part in quasis]
        raw = [quote(part["value"]["raw"]) for part in quasis]
        site = quote(f'{self.path}:{self.script_name}:{node["start"]}')
        return f'{self.scope}.template({site}, <dynamic>[{", ".join(cooked)}], <dynamic>[{", ".join(raw)}])'

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

    @staticmethod
    def dart_label(name):
        return "_jsLabel_" + "_".join(f"{ord(char):x}" for char in name)

    def loop_label(self, node):
        return "".join(f"{self.dart_label(name)}: " for name in node.get("htgcLabels", []))

    def loop_binding(self, target, value):
        if target["type"] == "VariableDeclaration":
            return self.bind(target["declarations"][0]["id"], value, target["kind"])
        return self.bind(target, value, "assign")

    def stmt(self, n):
        t = n["type"]
        if t == "LabeledStatement":
            labels = [n["label"]["name"]]
            body = n["body"]
            while body["type"] == "LabeledStatement":
                labels.append(body["label"]["name"])
                body = body["body"]
            labeled = {**body, "htgcLabels": labels}
            if body["type"] in ("ForStatement", "ForInStatement", "ForOfStatement", "WhileStatement", "DoWhileStatement"):
                return self.stmt(labeled)
            return f'{self.loop_label(labeled)}{{\n{self.stmt(body)}\n}}'
        if t == "ExpressionStatement":
            return self.expr(n["expression"]) + ";"
        if t in ("EmptyStatement", "DebuggerStatement"):
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
        if t == "ForInStatement":
            item = self.name("key")
            source = self.expr(n["right"])
            parent = self.scope
            self.scope = self.name()
            init = self.loop_binding(n["left"], item)
            body = self.stmt(n["body"])
            child, self.scope = self.scope, parent
            return (f'{self.loop_label(n)}for (final {item} in jForInKeys({source})) {{\n'
                    f'final {child} = JScope({parent});\n{init}\n{body}\n}}')
        if t == "ForOfStatement":
            asynchronous = n.get("await", False)
            if asynchronous and not self.asynchronous:
                self.fail(n, 'for await outside async function/module')
            iterator = self.name("item")
            source = self.expr(n["right"])
            parent = self.scope
            self.scope = self.name()
            init = self.loop_binding(n["left"], iterator)
            record = self.name("iterator")
            caught = self.name("error")
            factory = 'jGetAsyncIterator' if asynchronous else 'jGetIterator'
            def wait(expression):
                return f'(await jAwait({expression}))' if asynchronous else expression
            body = (f'{{ final {record} = {factory}({source});\ntry {{\n'
                    f'{self.loop_label(n)}while ({wait(f"{record}.advance()")}) {{\nfinal {iterator} = {record}.current;\n'
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
                + "\n" + self.loop_label(n) + "for (; "
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
                self.loop_label(n) + "while (jTruthy(" + self.expr(n["test"]) + ")) " + self.stmt(n["body"])
            )
        if t == "DoWhileStatement":
            return f'{self.loop_label(n)}do {{\n{self.stmt(n["body"])}\n}} while (jTruthy({self.expr(n["test"])}));'
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
            label = " " + self.dart_label(n["label"]["name"]) if n.get("label") else ""
            return ("break" if t == "BreakStatement" else "continue") + label + ";"
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
        body = node["body"]["body"]
        if self.has_await(node):
            self.fail(node, "await in class heritage or computed keys")
        name = (node.get("id") or {}).get("name", "")
        parent = self.scope
        inner, constructor, base = self.name("classScope"), self.name("class"), self.name("base")
        self.scope = inner
        previous_private = self.private_names
        try:
            superclass = node.get("superClass")
            base_expression = "null" if superclass is None else self.expr(superclass)
            source = f', source: {quote(node["htgcSource"])}' if "htgcSource" in node else ""
            code = [
                f"final {inner} = JScope({parent});",
                *([f"{inner}.reserve({quote(name)});"] if name else []),
                f"final {base} = {base_expression};",
                f'final {constructor} = jDefaultClass({quote(name)}, {base}, derived: '
                f'{str(superclass is not None).lower()}{source});',
            ]
            private = {}
            for item in body:
                key = item.get("key", {})
                if key.get("type") == "PrivateIdentifier" and key["name"] not in private:
                    private[key["name"]] = self.name("private")
            self.private_names = {**previous_private, **private}
            code.extend(f'final {slot} = JPrivateName();' for slot in private.values())
            static_steps, static_methods, installed = [], [], set()
            for item in body:
                item_key = item.get("key", {})
                private_slot = private.get(item_key["name"]) if item_key.get("type") == "PrivateIdentifier" else None
                static = item.get("static") or item["type"] == "StaticBlock"
                home = f'jClassHome({constructor}, {str(static).lower()})'
                if item["type"] == "MethodDefinition":
                    explicit = item["kind"] == "constructor"
                    key = None if explicit or private_slot else self.property_key(item)
                    function = self.function({
                        **item["value"], "htgc_method": True, "htgc_home": home,
                        "htgc_constructor": explicit,
                    })
                    if explicit:
                        code.append(f'jSetClassConstructor({constructor}, {function});')
                    elif private_slot:
                        code.append(f'{private_slot}.define({quote(item["kind"])}, {quote(item_key["name"])}, {function});')
                        if private_slot not in installed:
                            installed.add(private_slot)
                            if static:
                                static_methods.append(f'{private_slot}.install({constructor});')
                            else:
                                code.append(f'{constructor}.privateMethods.add({private_slot});')
                    else:
                        mode = "init" if item["kind"] == "method" else item["kind"]
                        code.append(f"jDefineClassMethod({constructor}, {str(static).lower()}, "
                                    f"{quote(mode)}, jPropertyKey({key}), {function});")
                    continue
                if item["type"] == "PropertyDefinition" and not private_slot:
                    key = self.name("field")
                    code.append(f'final {key} = jPropertyKey({self.property_key(item)});')
                old_this, old_home, old_context, old_target = self.receiver, self.home, self.construction, self.new_target
                self.receiver = constructor if static else self.name("instance")
                self.home, self.construction, self.new_target = home, None, "jUndefined"
                try:
                    if item["type"] == "PropertyDefinition":
                        value = self.expr(item.get("value"))
                        initializer = (f'{private_slot}.install({self.receiver}, {value});' if private_slot
                                       else f'jDefineClassField({self.receiver}, {key}, {value});')
                        if static:
                            static_steps.append(initializer)
                        else:
                            code.append(f'{constructor}.fields.add(({self.receiver}) {{ {initializer} }});')
                    elif item["type"] == "StaticBlock":
                        self.scope = self.name("staticScope")
                        step = self.block_contents(item["body"], hoist_vars=True)
                        static_steps.append(f'{{ final {self.scope} = JScope({inner});\n{step}\n}}')
                    else:
                        self.fail(item)
                finally:
                    self.scope = inner
                    self.receiver, self.home, self.construction, self.new_target = old_this, old_home, old_context, old_target
            if name:
                code.append(f"{inner}.define({quote(name)}, {constructor}, constant: true);")
            code.extend(static_methods)
            code.extend(static_steps)
            code.append(f"return {constructor};")
            return "(() {\n" + "\n".join(code) + "\n})()"
        finally:
            self.scope = parent
            self.private_names = previous_private

    def compile(self, ast, name):
        self.script_name = name
        body = self.block_contents(ast["body"], hoist_vars=True)
        return (
            f'// JavaScript source: {self.path.replace(chr(10)," ")}\nvoid {name}(JScope scope) {{\n'
            + self.temp_declarations() + body
            + "\n}\n"
        )


def compile_script(source, path, name="htgcScript"):
    return Compiler(path).compile(parse(source, path), name)
