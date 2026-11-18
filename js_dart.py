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


class JavaScriptSyntaxError(CompileError):
    """The JavaScript parser rejected the input grammar."""


def parse(source, path, *, source_type="module", allow_new_target=False, allow_super=False):
    node = shutil.which("node")
    parser = Path(__file__).parent / "javascript" / "parse.cjs"
    if not node:
        raise CompileError("JavaScriptの構文解析にはNode.jsが必要です")
    result = subprocess.run(
        [node, str(parser), *(["--script"] if source_type == "script" else []),
         *(["--eval-new-target"] if allow_new_target else []),
         *(["--eval-super"] if allow_super else [])],
        input=source, encoding="utf-8", capture_output=True
    )
    if result.returncode == 2:
        raise JavaScriptSyntaxError(f"{path}: JavaScript SyntaxError: {result.stderr.strip()}")
    if result.returncode:
        raise CompileError(
            f"{path}: JavaScript解析失敗: {result.stderr.strip()} (npm --prefix javascript ci)"
        )
    return json.loads(result.stdout)


RESOURCE_KINDS = ("using", "await using")


def is_resource_declaration(node):
    return node is not None and node["type"] == "VariableDeclaration" and node["kind"] in RESOURCE_KINDS


class Compiler:
    def __init__(self, path):
        self.path, self.serial, self.scope, self.receiver = (
            str(path),
            0,
            "scope",
            "jUndefined",
        )
        self.asynchronous = False
        self.strict = False
        self.new_target = "_noNewTarget"
        self.home = None
        self.construction = None
        self.private_names = {}
        self.temps = []
        self.module_owner = None
        self.module_key = None
        self.script_name = ""
        self.resource_stack = None
        self.eval_completion = None
        self.constructor_aliases = {"Function": "normal"}
        self.eval_aliases = set()

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
        return (
            node.get("type") == "AwaitExpression"
            or node.get("type") == "VariableDeclaration" and node.get("kind") == "await using"
            or any(Compiler.has_await(child) for child in node.values())
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
            return f'JRef.scope({self.scope}, {quote(node["name"])}, strict: {str(self.strict).lower()})'
        if node["type"] == "MemberExpression":
            if node["property"]["type"] == "PrivateIdentifier":
                return f'{self.private_name(node["property"])}.reference({self.expr(node["object"])})'
            if node["object"]["type"] == "Super":
                return self.super_reference(node)
            return f'JRef.member({self.expr(node["object"])}, {self.key(node)}, strict: {str(self.strict).lower()})'
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

    def object_entry(self, prop, key):
        kind = prop.get('kind', 'init')
        if prop.get('method') or kind in ('get', 'set'):
            home = self.name('home')
            value = self.function({**prop['value'], 'htgc_method': True, 'htgc_home': home})
            return f'({quote(kind)}, {key}, (JObject {home}) => {value})'
        if (not prop.get('computed') and not prop.get('shorthand')
                and prop['key'].get('name', prop['key'].get('value')) == '__proto__'):
            kind = 'prototype'
        return f'({quote(kind)}, {key}, {self.expr(prop["value"])})'

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
                return f'{self.ref(pattern)}.write({value});'
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

    @staticmethod
    def strict_directive(statements):
        for statement in statements:
            directive = statement.get("directive")
            if directive is None:
                return False
            if directive == "use strict":
                return True
        return False

    def function_value(self, node):
        previous_strict = self.strict
        body = node["body"]
        self.strict = self.strict or self.strict_directive(body.get("body", []))
        previous, self.eval_completion = self.eval_completion, None
        try:
            return self.function_body(node)
        finally:
            self.eval_completion = previous
            self.strict = previous_strict

    def function_body(self, node):
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
        body = [f"final {scope} = JScope.function({old_scope});"]
        if not arrow and not self.strict and not node.get("htgc_constructor"):
            self.receiver = self.name("thisValue")
            body.append(f'final {self.receiver} = jNullish({receiver}) ? {scope}.globalThisValue : jObject({receiver});')
        setup, callee = self.function_parameters(node, args)
        body.extend(setup)
        if node["body"]["type"] == "BlockStatement":
            body.append(self.block_contents(node["body"]["body"], hoist_vars=True, global_functions=True))
            if not self.returns(node["body"]):
                body.append("throw JAsyncReturn(jUndefined);" if self.asynchronous else "return jUndefined;")
        else:
            value = self.expr(node["body"])
            body.append(f'throw JAsyncReturn({value});' if self.asynchronous else f'return {value};')
        code = self.temp_declarations() + "\n".join(body)
        result = (
            f"jAsyncFunction(JFunction(({args}, {receiver}) => {self.async_body(code)}, constructible: false))"
            if self.asynchronous else (
                f"JFunction(({args}, {receiver}) {{\n{code}\n}}, constructible: false)"
                if node["type"] == "ArrowFunctionExpression" or node.get("htgc_method") else
                f"jFunction(({args}, {receiver}, {self.new_target}) {{\n{code}\n}})"
            )
        )
        self.scope, self.receiver, self.new_target = old_scope, old_this, old_target
        self.home, self.construction = old_home, old_construction
        self.asynchronous, self.temps = old_async, old_temps
        return self.function_metadata(self.capture_callee(result, callee), node)

    def function_parameters(self, node, args):
        params = node["params"]
        simple = all(p["type"] == "Identifier" for p in params)
        names = [n for p in params for n in self.binding_names(p)]
        scope = self.scope
        code = []
        callee = None
        statements = node["body"]["body"] if node["body"]["type"] == "BlockStatement" else []
        shadows_arguments = any(
            (n["type"] in ("FunctionDeclaration", "ClassDeclaration") and n["id"]["name"] == "arguments") or
            (n["type"] == "VariableDeclaration" and n["kind"] != "var" and
             any("arguments" in self.binding_names(d["id"]) for d in n["declarations"]))
            for n in statements
        )
        if (node["type"] != "ArrowFunctionExpression" and "arguments" not in names
                and not (simple and shadows_arguments)):
            extras = ""
            if simple and not self.strict:
                callee = self.name("callee")
                formal_names = ", ".join(map(quote, names))
                extras = f", environment: {scope}, names: [{formal_names}], callee: {callee}"
            code.append(f'{scope}.define("arguments", jArgumentsObject({args}{extras}));')
        if not simple:
            code.extend(f'{scope}.reserve({quote(name)});' for name in names)
        for i, param in enumerate(params):
            if simple and param["name"] in names[i + 1:]:
                continue
            value = f"jArg({args}, {i})"
            if param["type"] == "RestElement":
                value, param = f"{args}.skip({i}).toList()", param["argument"]
            if param["type"] == "AssignmentPattern":
                value = f'jDefault({value}, () => {self.expr(param["right"])})'
                param = param["left"]
            code.append(self.bind(param, value))
        if not simple:
            self.scope = self.name("vars")
            code.append(f'final {self.scope} = JScope.function({scope});')
            for name in dict.fromkeys(self.var_names(statements)):
                if name in names or name == 'arguments' and node["type"] != "ArrowFunctionExpression":
                    code.append(f'{self.scope}.define({quote(name)}, {scope}.get({quote(name)}));')
        return code, callee

    @staticmethod
    def capture_callee(expression, callee):
        if callee is None:
            return expression
        return f'(() {{ late final JFunction {callee}; return {callee} = {expression}; }})()'

    def function_metadata(self, expression, node):
        length = 0
        for param in node['params']:
            if param['type'] in ('AssignmentPattern', 'RestElement'):
                break
            length += 1
        name = node.get('htgcInferredName', (node.get('id') or {}).get('name', ''))
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

    def call_site(self, callee, optional=False):
        if callee["type"] == "Identifier":
            return (f'{self.scope}.callSite({quote(callee["name"])}, strict: {str(self.strict).lower()}, '
                    f'optional: {str(optional).lower()})')
        return f'JCallSite({self.expr(callee)}, optional: {str(optional).lower()})'

    def runtime_eval(self, target, arguments, receiver="jUndefined"):
        return (f'jDirectRuntimeEval({target}, {arguments}, {self.scope}, {self.receiver}, '
                f'strict: {str(self.strict).lower()}, newTarget: {self.new_target}, home: {self.home or "null"}, receiver: {receiver})')

    def compiled_eval(self, source, *, indirect=False):
        try:
            ast = parse(source, f"{self.path}:eval", source_type="script" if indirect or not self.strict else "module",
                        allow_new_target=not indirect and self.new_target != "_noNewTarget",
                        allow_super=not indirect and self.home is not None)
        except CompileError:
            return '() { throw JThrown(JError("SyntaxError", "Invalid eval source")); }'
        self.collect_constructor_aliases(ast)
        nodes = ast["body"]
        if self.has_await(nodes) or any(
            node["type"] in ("ImportDeclaration", "ExportNamedDeclaration", "ExportDefaultDeclaration", "ExportAllDeclaration")
            for node in nodes
        ):
            return '() { throw JThrown(JError("SyntaxError", "Invalid eval source")); }'
        parent, self.scope = self.scope, self.name("eval")
        scope = self.scope
        previous, self.eval_completion = self.eval_completion, self.name("completion")
        old_receiver, old_target, old_home = self.receiver, self.new_target, self.home
        if indirect:
            self.receiver = f'{scope}.globalScope.globalThisValue'
            self.new_target, self.home = '_noNewTarget', None
        completion = self.eval_completion
        previous_strict = self.strict
        self.strict = (self.strict and not indirect) or self.strict_directive(nodes)
        try:
            vars_ = ", ".join(map(quote, dict.fromkeys(self.var_names(nodes))))
            functions = ", ".join(quote(n["id"]["name"]) for n in nodes if n["type"] == "FunctionDeclaration")
            prepare = f'{scope}.prepareEval({str(self.strict).lower()}, [{vars_}], [{functions}]);'
            body = self.block_contents(nodes, hoist_vars=True, global_functions=True)
        except CompileError:
            return '() { throw JThrown(JError("TypeError", "Unsupported eval source")); }'
        finally:
            self.scope, self.eval_completion, self.receiver = parent, previous, old_receiver
            self.new_target, self.home = old_target, old_home
            self.strict = previous_strict
        environment = f'{parent}.scriptGlobalScope' if indirect else parent
        return (f'() {{\n// ignore: unused_local_variable\nfinal {scope} = JScope({environment});\n{prepare}\n'
                f'dynamic {completion} = jUndefined;\n{body}\nreturn {completion}; }}')

    def function_constructor_kind(self, callee):
        if callee["type"] == "Identifier":
            return self.constructor_aliases.get(callee["name"])
        if (callee["type"] != "MemberExpression" or callee.get("computed")
                or callee["property"].get("name") != "constructor"):
            return None
        value = callee["object"]
        if (value["type"] == "CallExpression" and value["callee"].get("type") == "MemberExpression"
                and value["callee"]["object"].get("name") == "Object"
                and value["callee"]["property"].get("name") == "getPrototypeOf"
                and len(value["arguments"]) == 1):
            value = value["arguments"][0]
        if value["type"] not in ("FunctionExpression", "ArrowFunctionExpression"):
            return None
        if value.get("generator"):
            return "asyncGenerator" if value.get("async") else "generator"
        return "async" if value.get("async") else "normal"

    def collect_constructor_aliases(self, ast):
        def visit(node):
            if isinstance(node, list):
                for child in node:
                    visit(child)
            elif isinstance(node, dict):
                if node.get("type") == "VariableDeclarator" and node["id"]["type"] == "Identifier" and node.get("init"):
                    kind = self.function_constructor_kind(node["init"])
                    if kind is not None:
                        self.constructor_aliases[node["id"]["name"]] = kind
                    init = node["init"]
                    if (init.get("type") == "Identifier" and init.get("name") == "eval") or (
                        init.get("type") == "MemberExpression"
                        and (init["property"].get("value") if init.get("computed") else init["property"].get("name")) == "eval"
                    ):
                        self.eval_aliases.add(node["id"]["name"])
                for value in node.values():
                    visit(value)
        visit(ast)

    def compiled_function(self, arguments, kind="normal"):
        parameters = ','.join(item['value'] for item in arguments[:-1])
        body = arguments[-1]['value'] if arguments else ''
        prefix = "async " if kind in ("async", "asyncGenerator") else ""
        star = "*" if kind in ("generator", "asyncGenerator") else ""
        header = f'({prefix}function{star} anonymous({parameters}\n) '
        source = f'{header}{{\n{body}\n}})'
        try:
            ast = parse(source, f"{self.path}:Function", source_type="script")
            self.collect_constructor_aliases(ast)
            nodes = ast['body']
            function = nodes[0].get('expression', {}) if len(nodes) == 1 else {}
            header_end = len(header.encode('utf-16-le', errors='surrogatepass')) // 2
            if (function.get('type') != 'FunctionExpression' or function['body']['start'] != header_end
                    or function['end'] != len(source.encode('utf-16-le', errors='surrogatepass')) // 2 - 1):
                raise CompileError('Invalid dynamic function body or parameters')
            function = {**function, 'type': 'FunctionDeclaration'}
        except CompileError:
            return '() { throw JThrown(JError("SyntaxError", "Invalid Function source")); }'
        parent, self.scope = self.scope, self.name('global')
        scope = self.scope
        previous_strict, self.strict = self.strict, False
        try:
            expression = self.function(function)
        finally:
            self.scope = parent
            self.strict = previous_strict
        return f'() {{ final {scope} = {parent}.scriptGlobalScope; return {expression}; }}'

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
            return (
                f'{self.scope}.modules(htgcModules).importModule('
                f'{quote(self.module_owner)}, {self.expr(n["source"])}, {self.expr(n.get("options"))})'
            )
        if t == "ClassExpression":
            return self.class_expression(n)
        if t == "Identifier":
            return f'{self.scope}.get({quote(n["name"])}, strict: {str(self.strict).lower()})'
        if t == "MetaProperty":
            if n["meta"]["name"] == "new":
                return self.new_target
            if self.module_key is None:
                self.fail(n, "import.meta requires an HTML module script")
            return (
                f'{self.scope}.modules(htgcModules).meta('
                f'{quote(self.module_key)}, {quote(self.module_owner)})'
            )
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
            return "JArray(<dynamic>[" + ", ".join(parts) + "])"
        if t == "ObjectExpression":
            parts = []
            for p in n["properties"]:
                if p["type"] == "SpreadElement":
                    parts.append("...jObjectSpread(" + self.expr(p["argument"]) + ")")
                    continue
                key = self.property_key(p)
                parts.append(self.object_entry(p, f'jPropertyKey({key})'))
            return "jObjectLiteral([" + ", ".join(parts) + "])"
        if t in ("FunctionExpression", "ArrowFunctionExpression"):
            return self.function(n)
        if t == "TaggedTemplateExpression":
            tag = n["tag"]
            callee = self.member(tag, call=True) if tag["type"] == "MemberExpression" else self.call_site(tag)
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
            arguments = n["arguments"]
            literal_eval = (t == "CallExpression" and arguments
                            and arguments[0]["type"] == "Literal"
                            and isinstance(arguments[0].get("value"), str))
            indirect_eval = (
                callee["type"] == "SequenceExpression"
                and callee["expressions"][-1].get("name") == "eval"
            ) or (
                callee["type"] == "Identifier" and callee["name"] == "eval"
                and n.get("optional")
            ) or (
                callee["type"] == "Identifier" and callee["name"] != "eval" and callee["name"] in self.eval_aliases
            ) or (
                callee["type"] == "MemberExpression" and
                (callee["property"].get("value") if callee.get("computed")
                 else callee["property"].get("name")) == "eval"
            )
            if literal_eval and indirect_eval:
                callsite = (self.member(callee, call=True, optional_call=n.get("optional", False))
                            if callee["type"] == "MemberExpression"
                            else self.call_site(callee, n.get("optional", False)))
                temp = self.temp()
                return (f'(({temp} = {callsite}).skipped ? jShortCircuit : '
                        f'jCompiledEval({temp}.function, {args}, '
                        f'{self.compiled_eval(arguments[0]["value"], indirect=True)}, receiver: {temp}.receiver))')
            if callee["type"] == "Identifier" and not n.get("optional"):
                name = callee["name"]
                arguments = n["arguments"]
                if (t == "CallExpression" and name == "eval" and arguments
                        and arguments[0]["type"] == "Literal"
                        and isinstance(arguments[0].get("value"), str)):
                    temp = self.temp()
                    return (f'jCompiledEval(({temp} = {self.call_site(callee)}).function, {args}, '
                            f'{self.compiled_eval(arguments[0]["value"])}, receiver: {temp}.receiver)')
                if t == "CallExpression" and name == "eval":
                    temp = self.temp()
                    return self.runtime_eval(f'({temp} = {self.call_site(callee)}).function', args, f'{temp}.receiver')
                constructor_kind = self.function_constructor_kind(callee)
                if (constructor_kind is not None and all(item["type"] == "Literal" and
                        isinstance(item.get("value"), str) for item in arguments)):
                    construct = str(t == "NewExpression").lower()
                    temp = self.temp()
                    return (f'jCompiledFunction(({temp} = {self.call_site(callee)}).function, {args}, '
                            f'{self.compiled_function(arguments, constructor_kind)}, '
                            f'construct: {construct}, kind: {quote(constructor_kind)}, receiver: {temp}.receiver)')
            constructor_kind = self.function_constructor_kind(callee)
            if (constructor_kind is not None and callee["type"] == "MemberExpression"
                    and not n.get("optional") and not callee.get("optional")
                    and all(item["type"] == "Literal" and isinstance(item.get("value"), str)
                            for item in n["arguments"])):
                callsite = self.temp()
                construct = str(t == "NewExpression").lower()
                return (f'(({callsite} = {self.member(callee, call=True)}).skipped ? jShortCircuit : '
                        f'jCompiledFunction({callsite}.function, {args}, '
                        f'{self.compiled_function(n["arguments"], constructor_kind)}, '
                        f'construct: {construct}, kind: {quote(constructor_kind)}, receiver: {callsite}.receiver))')
            if "htgcLoweredRegExp" in n:
                return self.precompiled_regexp(n, self.expr(callee), args)
            if t == "NewExpression":
                return f"jNew({self.expr(callee)}, {args})"
            if callee["type"] == "MemberExpression":
                callsite = self.member(callee, call=True, optional_call=n.get("optional", False))
            else:
                callsite = self.call_site(callee, n.get("optional", False))
            if n.get("optional") or callee.get("optional") or callee["type"] == "MemberExpression":
                temp = self.temp()
                return f'(({temp} = {callsite}).skipped ? jShortCircuit : {temp}.call({args}))'
            return f"{callsite}.call({args})"
        if t == "UnaryExpression":
            if n["operator"] == "typeof" and n["argument"]["type"] == "Identifier":
                return f'jUnary("typeof", {self.scope}.getForTypeof({quote(n["argument"]["name"])}, strict: {str(self.strict).lower()}))'
            if n["operator"] == "delete" and n["argument"]["type"] == "Identifier":
                return f'{self.scope}.deleteBinding({quote(n["argument"]["name"])})'
            if n["operator"] == "delete" and n["argument"]["type"] == "MemberExpression":
                target = n["argument"]
                return f'jDelete({self.expr(target["object"])}, {self.key(target)}, strict: {str(self.strict).lower()})'
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

    def wait_for_disposal(self, expression):
        return f"await jAwait({expression});"

    def resource_region(self, nodes, body):
        resources = [
            node["kind"] for node in nodes
            if is_resource_declaration(node)
        ]
        if not resources:
            return body()
        previous = self.resource_stack
        stack = self.resource_stack = self.name("resources")
        pending, caught = self.name("pending"), self.name("error")
        try:
            code = body()
        finally:
            self.resource_stack = previous
        cleanup = f"{stack}.dispose({pending});"
        if "await using" in resources:
            cleanup = (
                f"if ({stack}.hasAsync) {{\n"
                + self.wait_for_disposal(f"{stack}.disposeAsync({pending})")
                + f"\n}} else {{ {cleanup} }}"
            )
        return (
            f"final {stack} = JResources();\nObject? {pending};\ntry {{\n{code}\n"
            f"}} catch ({caught}) {{\n{pending} = {caught};\nrethrow;\n"
            f"}} finally {{\n{cleanup}\n}}"
        )

    def bind_resource(self, pattern, value, kind):
        asynchronous = str(kind == "await using").lower()
        return self.bind(
            pattern, f"{self.resource_stack}.add({value}, asynchronous: {asynchronous})", "const"
        )

    def reserve_lexical(self, nodes):
        names = []
        for node in nodes:
            if not node:
                continue
            if node["type"] == "VariableDeclaration" and node["kind"] != "var":
                for entry in node["declarations"]:
                    names.extend(self.binding_names(entry["id"]))
            elif node["type"] == "ClassDeclaration":
                names.append(node["id"]["name"])
        return [f"{self.scope}.reserve({quote(name)});" for name in names]

    def block_contents(self, nodes, *, hoist_vars=False, global_functions=False):
        def contents():
            # Function declarations are initialized before the surrounding statements.
            code = self.reserve_lexical(nodes)
            code.extend(
                f'{self.scope}.declareFunction({quote(n["id"]["name"])}, {self.function(n)});'
                if global_functions else self.stmt(n)
                for n in nodes if n["type"] == "FunctionDeclaration"
            )
            if hoist_vars:
                code.extend(
                    f"{self.scope}.declareVar({quote(name)});"
                    for name in dict.fromkeys(self.var_names(nodes))
                )
            code.extend(self.stmt(n) for n in nodes if n["type"] != "FunctionDeclaration")
            return "\n".join(code)
        return self.resource_region(nodes, contents)

    def switch(self, node):
        cases = node["cases"]
        discriminant = self.expr(node["discriminant"])
        declarations = [stmt for case in cases for stmt in case["consequent"]]
        return "{\n" + self.resource_region(
            declarations, lambda: self.switch_body(cases, discriminant, declarations)
        ) + "\n}"

    def switch_body(self, cases, discriminant, declarations):
        if not cases:
            return discriminant + ";"
        value, selected = self.name("value"), self.name("case")
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
        code.extend(self.reserve_lexical(declarations))
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
            pattern = target["declarations"][0]["id"]
            if target["kind"] in RESOURCE_KINDS:
                return self.bind_resource(pattern, value, target["kind"])
            return self.bind(pattern, value, target["kind"])
        return self.bind(target, value, "assign")

    def loop_source(self, node):
        left = node["left"]
        if left["type"] != "VariableDeclaration" or left["kind"] == "var":
            return self.expr(node["right"])
        parent = self.scope
        self.scope = self.name("head")
        scope = self.scope
        reservations = "\n".join(self.reserve_lexical([left]))
        source = self.expr(node["right"])
        self.scope = parent
        asynchronous = self.has_await(node["right"])
        result = (f"(() {'async ' if asynchronous else ''}{{\n"
                  f"final {scope} = JScope({parent});\n{reservations}\nreturn {source};\n}})()")
        return f"(await {result})" if asynchronous else result

    def lexical_for(self, node):
        parent = self.scope
        initial, control = self.name("initial"), self.name("control")
        condition_scope, update_scope, body_scope = (
            self.name("condition"), self.name("update"), self.name("iteration")
        )
        names = list(dict.fromkeys(
            name for declaration in node["init"]["declarations"]
            for name in self.binding_names(declaration["id"])
        ))
        name_list = "<String>[" + ", ".join(quote(name) for name in names) + "]"
        self.scope = initial
        initial_code = "\n".join([
            *self.reserve_lexical([node["init"]]), self.stmt(node["init"])
        ])
        self.scope = condition_scope
        condition = "true" if not node.get("test") else "jTruthy(" + self.expr(node["test"]) + ")"
        self.scope = update_scope
        update = self.expr(node.get("update"))
        self.scope = body_scope
        body = self.stmt(node["body"])
        self.scope = parent
        condition_async = self.has_await(node.get("test"))
        update_async = self.has_await(node.get("update"))
        condition_call = (
            f"(() {'async ' if condition_async else ''}{{ final {condition_scope} = {control}; "
            f"return {condition}; }})()"
        )
        update_call = (
            f"(() {'async ' if update_async else ''}{{ final {update_scope} = {control}.copyIteration({name_list}); "
            f"{control} = {update_scope}; {update}; }})()"
        )
        if condition_async:
            condition_call = f"(await {condition_call})"
        if update_async:
            update_call = f"(await {update_call})"
        return (
            f"{{\nfinal {initial} = JScope({parent});\n{initial_code}\n"
            f"var {control} = {initial}.copyIteration({name_list});\n"
            f"{self.loop_label(node)}for (; {condition_call}; {update_call}) {{\n"
            f"final {body_scope} = {control};\n{body}\n}}\n}}"
        )

    def stmt(self, n):
        t = n["type"]
        if (self.eval_completion and not n.get("htgcEvalNoReset") and t in (
                "IfStatement", "ForStatement", "ForInStatement", "ForOfStatement",
                "WhileStatement", "DoWhileStatement", "SwitchStatement", "TryStatement", "WithStatement")):
            return (f"{{ {self.eval_completion} = jUndefined;\n"
                    + self.stmt({**n, "htgcEvalNoReset": True}) + "\n}")
        if t == "WithStatement":
            target = self.expr(n["object"])
            parent, self.scope = self.scope, self.name("with")
            try:
                return f'{{\nfinal {self.scope} = JWithScope({parent}, {target});\n{self.stmt(n["body"])}\n}}'
            finally:
                self.scope = parent
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
            expression = self.expr(n["expression"])
            return (f"{self.eval_completion} = {expression};" if self.eval_completion
                    else expression + ";")
        if t in ("EmptyStatement", "DebuggerStatement"):
            return ";"
        if t == "VariableDeclaration":
            if n["kind"] in RESOURCE_KINDS:
                return "\n".join(
                    self.bind_resource(d["id"], self.expr(d["init"]), n["kind"])
                    for d in n["declarations"]
                )
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
            source = self.loop_source(n)
            parent = self.scope
            self.scope = self.name()
            init = self.loop_binding(n["left"], item)
            reservations = "\n".join(self.reserve_lexical([n["left"]]))
            body = self.stmt(n["body"])
            child, self.scope = self.scope, parent
            return (f'{self.loop_label(n)}for (final {item} in jForInKeys({source})) {{\n'
                    f'final {child} = JScope({parent});\n{reservations}\n{init}\n{body}\n}}')
        if t == "ForOfStatement":
            asynchronous = n.get("await", False)
            if asynchronous and not self.asynchronous:
                self.fail(n, 'for await outside async function/module')
            iterator = self.name("item")
            source = self.loop_source(n)
            parent = self.scope
            self.scope = self.name()
            iteration = self.resource_region(
                [n["left"]],
                lambda: "\n".join([
                    *self.reserve_lexical([n["left"]]),
                    self.loop_binding(n["left"], iterator), self.stmt(n["body"]),
                ]),
            )
            record = self.name("iterator")
            caught = self.name("error")
            factory = 'jGetAsyncIterator' if asynchronous else 'jGetIterator'
            def wait(expression):
                return f'(await jAwait({expression}))' if asynchronous else expression
            body = (f'{{ final {record} = {factory}({source});\ntry {{\n'
                    f'{self.loop_label(n)}while ({wait(f"{record}.advance()")}) {{\nfinal {iterator} = {record}.current;\n'
                    f'final {self.scope} = JScope({parent});\n{iteration}\n}}'
                    f'\n}} catch ({caught}) {{\n{wait(f"{record}.close(suppressErrors: {caught} is! JAsyncReturn)")};\nrethrow;\n}}'
                    f' finally {{ {wait(f"{record}.close()")}; }}\n}}')
            self.scope = parent
            return body
        if t == "ForStatement":
            init = n.get("init")
            if init and init["type"] == "VariableDeclaration" and init["kind"] == "let":
                return self.lexical_for(n)
            if not n.get("htgcResources") and is_resource_declaration(n.get("init")):
                return "{\n" + self.resource_region(
                    [n.get("init")], lambda: self.stmt({**n, "htgcResources": True})
                ) + "\n}"
            parent = self.scope
            self.scope = self.name()
            reservations = self.reserve_lexical([n["init"]]) if n.get("init") else []
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
                + "\n".join([*reservations, init])
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
                if (handler.get("param") or {}).get("type") == "Identifier":
                    code += f'{self.scope}.simpleCatchName = {quote(handler["param"]["name"])};\n'
                if self.asynchronous:
                    code += f"if ({caught} is JAsyncReturn) rethrow;\n"
                value = f"{caught} is JThrown ? {caught}.value : {caught}"
                if handler["param"] is not None:
                    code += self.bind(handler["param"], value) + "\n"
                code += self.stmt(handler["body"]) + "\n}"
                self.scope = parent
            if n.get("finalizer") is not None:
                completion, self.eval_completion = self.eval_completion, None
                try:
                    code += " finally " + self.stmt(n["finalizer"])
                finally:
                    self.eval_completion = completion
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
        code, constructor = self.class_definition(node)
        definition = "\n".join(code)
        if not self.has_await(node):
            return f"(() {{\n{definition}\nreturn {constructor};\n}})()"
        evaluation, temporary = self.name("evaluation"), self.temp()
        return (
            f"(({temporary} = jEvaluateAsyncClass(({evaluation}) async {{\n"
            f"try {{\n{definition}\n{evaluation}.complete({constructor});\n"
            f"}} catch (error, stack) {{ {evaluation}.fail(error, stack); }}\n"
            f"}})).completed ? {temporary}.value : await {temporary}.pending)"
        )

    def class_value(self, code, compile_value):
        return compile_value()

    def class_member_body(self, compile_body):
        return compile_body()

    def class_definition(self, node):
        body = node["body"]["body"]
        name = (node.get("id") or {}).get("name", "")
        inferred_name = node.get("htgcInferredName")
        binding = "" if inferred_name is not None else name
        display = inferred_name if inferred_name is not None else name
        parent = self.scope
        inner, constructor, base = self.name("classScope"), self.name("class"), self.name("base")
        self.scope = inner
        previous_private = self.private_names
        previous_strict, self.strict = self.strict, True
        try:
            superclass = node.get("superClass")
            source = f', source: {quote(node["htgcSource"])}' if "htgcSource" in node else ""
            code = [f"final {inner} = JScope({parent});"]
            if binding:
                code.append(f"{inner}.reserve({quote(binding)});")
            base_expression = "null" if superclass is None else self.class_value(
                code, lambda: self.expr(superclass))
            code.extend([
                f"final {base} = {base_expression};",
                f'final {constructor} = jDefaultClass({quote(display)}, {base}, derived: '
                f'{str(superclass is not None).lower()}{source});',
            ])
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
                    key = None if explicit or private_slot else self.class_value(
                        code, lambda: self.property_key(item))
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
                    expression = self.class_value(code, lambda: self.property_key(item))
                    code.append(f'final {key} = jPropertyKey({expression});')
                old_this, old_home, old_context, old_target = self.receiver, self.home, self.construction, self.new_target
                self.receiver = constructor if static else self.name("instance")
                self.home, self.construction, self.new_target = home, None, "jUndefined"
                try:
                    if item["type"] == "PropertyDefinition":
                        value = self.class_member_body(lambda: self.expr(item.get("value")))
                        initializer = (f'{private_slot}.install({self.receiver}, {value});' if private_slot
                                       else f'jDefineClassField({self.receiver}, {key}, {value});')
                        if static:
                            static_steps.append(initializer)
                        else:
                            code.append(f'{constructor}.fields.add(({self.receiver}) {{ {initializer} }});')
                    elif item["type"] == "StaticBlock":
                        self.scope = self.name("staticScope")
                        step = self.class_member_body(
                            lambda: self.block_contents(item["body"], hoist_vars=True))
                        static_steps.append(f'{{ final {self.scope} = JScope({inner});\n{step}\n}}')
                    else:
                        self.fail(item)
                finally:
                    self.scope = inner
                    self.receiver, self.home, self.construction, self.new_target = old_this, old_home, old_context, old_target
            if binding:
                code.append(f"{inner}.define({quote(binding)}, {constructor}, constant: true);")
            code.extend(static_methods)
            code.extend(static_steps)
            return code, constructor
        finally:
            self.scope = parent
            self.private_names = previous_private
            self.strict = previous_strict

    def compile(self, ast, name):
        self.script_name = name
        self.receiver = 'scope.scriptThis'
        self.strict = ast.get('sourceType') == 'module' or self.strict_directive(ast['body'])
        self.collect_constructor_aliases(ast)
        body = self.block_contents(ast["body"], hoist_vars=True, global_functions=True)
        return (
            f'// JavaScript source: {self.path.replace(chr(10)," ")}\nvoid {name}(JScope scope) {{\n'
            + self.temp_declarations() + body
            + "\n}\n"
        )


def compile_script(source, path, name="htgcScript", *, source_type="module"):
    return Compiler(path).compile(parse(source, path, source_type=source_type), name)
