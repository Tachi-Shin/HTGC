"""Emit C11 expressions and closures from the JavaScript syntax tree."""

from c_source import c_string
from frontend import CompileError
from js_dart import parse


class CEmitter:
    def __init__(self, source, name):
        self.source = source
        self.name = name
        self.serial = 0
        self.scope = "scope"
        self.receiver = "js_undefined"
        self.lines = []
        self.functions = []
        self.continues = []

    def fresh(self, kind):
        self.serial += 1
        return f"{kind}_{self.serial}"

    def line(self, code):
        self.lines.append(code)

    def value(self, expression):
        name = self.fresh("value")
        self.line(f"JsValue {name} = {expression};")
        return name

    def fail(self, node, description=None):
        line = node["loc"]["start"]["line"]
        raise CompileError(
            f'{self.source}:{line}: CへのJavaScript変換は未対応: {description or node["type"]}'
        )

    def function(self, node):
        if node.get("async") or node.get("generator"):
            self.fail(node, "async/generator function")
        name = f'{self.name}_{self.fresh("function")}'
        previous = self.lines, self.scope, self.receiver, self.continues
        self.lines, self.scope, self.receiver, self.continues = (
            [],
            "scope",
            "receiver",
            [],
        )
        self.line("JsScope *scope = js_scope(parent);")
        self.line("(void)scope; (void)receiver; (void)arguments;")
        for index, param in enumerate(node["params"]):
            if param["type"] != "Identifier":
                self.fail(param)
            self.line(
                f'js_define(scope, {c_string(param["name"])}, js_arg(arguments, {index}));'
            )
        body = node["body"]
        if body["type"] == "BlockStatement":
            self.block(body["body"])
            if not body["body"] or body["body"][-1]["type"] != "ReturnStatement":
                self.line("return js_undefined;")
        else:
            result = self.expr(body)
            self.line(f"return {result};")
        code = "\n".join(self.lines)
        self.functions.append(
            f"static JsValue {name}(JsScope *parent, JsValue receiver, JsArgs arguments) {{\n{code}\n}}"
        )
        self.lines, self.scope, self.receiver, self.continues = previous
        arrow = node["type"] == "ArrowFunctionExpression"
        return self.value(
            f"js_function({name}, {self.scope}, {str(arrow).lower()}, {self.receiver})"
        )

    def key(self, node):
        if node.get("computed"):
            value = self.expr(node["property"])
            return f"js_to_string({value})"
        return c_string(node["property"]["name"])

    def args(self, nodes):
        values = [self.expr(node) for node in nodes]
        if not values:
            return "(JsArgs){0, NULL}"
        return f'(JsArgs){{{len(values)}, (JsValue[]){{{", ".join(values)}}}}}'

    def reference(self, node):
        if node["type"] == "Identifier":
            name = c_string(node["name"])
            return (
                f"js_get_name({self.scope}, {name})",
                f"js_assign({self.scope}, {name}, {{value}})",
            )
        if node["type"] == "MemberExpression":
            obj = self.expr(node["object"])
            key = self.fresh("key")
            self.line(f"const char *{key} = {self.key(node)};")
            return f"js_get({obj}, {key})", f"js_set({obj}, {key}, {{value}})"
        self.fail(node)

    def expr(self, node):
        if node is None:
            return "js_undefined"
        kind = node["type"]
        if kind == "Identifier":
            return self.value(f'js_get_name({self.scope}, {c_string(node["name"])})')
        if kind == "ThisExpression":
            return self.receiver
        if kind == "Literal":
            if "regex" in node:
                pattern = node["regex"]
                return self.value(
                    f'js_regex({c_string(pattern["pattern"])}, {c_string(pattern["flags"])})'
                )
            literal = node["value"]
            if literal is None:
                return "js_null"
            if isinstance(literal, bool):
                return f"js_bool({str(literal).lower()})"
            if isinstance(literal, str):
                return self.value(f"js_string({c_string(literal)})")
            return self.value(f"js_number({float(literal)!r})")
        if kind in ("FunctionExpression", "ArrowFunctionExpression"):
            return self.function(node)
        if kind == "ArrayExpression":
            return self.value(f'js_array({self.args(node["elements"])})')
        if kind == "ObjectExpression":
            obj = self.value("js_object()")
            for prop in node["properties"]:
                if prop["type"] != "Property" or prop["kind"] != "init":
                    self.fail(prop)
                key = (
                    self.key({"computed": prop["computed"], "property": prop["key"]})
                    if prop["computed"]
                    else c_string(
                        str(prop["key"].get("name", prop["key"].get("value")))
                    )
                )
                item = self.expr(prop["value"])
                self.line(f"js_set({obj}, {key}, {item});")
            return obj
        if kind == "TemplateLiteral":
            parts = []
            for index, text in enumerate(node["quasis"]):
                parts.append(f'js_string({c_string(text["value"]["cooked"])})')
                if index < len(node["expressions"]):
                    parts.append(self.expr(node["expressions"][index]))
            return self.value(
                f'js_join((JsArgs){{{len(parts)}, (JsValue[]){{{", ".join(parts)}}}}})'
            )
        if kind == "ChainExpression":
            operand = self.expr(node["expression"])
            return self.value(f"js_end_chain({operand})")
        if kind == "MemberExpression":
            obj = self.expr(node["object"])
            result = self.value("js_short")
            condition = f"{obj}.kind != JS_SHORT"
            if node.get("optional"):
                condition += f" && !js_nullish({obj})"
            self.line(f"if ({condition}) {{")
            key = self.key(node)
            self.line(f"{result} = js_get({obj}, {key});")
            self.line("}")
            return result
        if kind in ("CallExpression", "NewExpression"):
            callee = node["callee"]
            receiver = "js_undefined"
            if callee["type"] == "MemberExpression":
                receiver = self.expr(callee["object"])
                fn = self.value("js_short")
                condition = f"{receiver}.kind != JS_SHORT"
                if callee.get("optional"):
                    condition += f" && !js_nullish({receiver})"
                self.line(f"if ({condition}) {{")
                key = self.key(callee)
                self.line(f"{fn} = js_get({receiver}, {key});")
                self.line("}")
            else:
                fn = self.expr(callee)
            # Ensure even literal callees have an addressable value before testing the tag.
            fn = self.value(fn)
            result = self.value("js_short")
            condition = f"{fn}.kind != JS_SHORT"
            if node.get("optional"):
                condition += f" && !js_nullish({fn})"
            self.line(f"if ({condition}) {{")
            args = self.args(node["arguments"])
            if kind == "NewExpression":
                self.line(f"{result} = js_new({fn}, {args});")
            else:
                self.line(f"{result} = js_call({fn}, {receiver}, {args});")
            self.line("}")
            return result
        if kind == "UnaryExpression":
            operand = self.expr(node["argument"])
            return self.value(f'js_unary({c_string(node["operator"])}, {operand})')
        if kind == "BinaryExpression":
            left = self.expr(node["left"])
            right = self.expr(node["right"])
            return self.value(
                f'js_binary({c_string(node["operator"])}, {left}, {right})'
            )
        if kind == "LogicalExpression":
            left = self.expr(node["left"])
            result = self.value(left)
            condition = {
                "&&": f"js_truthy({result})",
                "||": f"!js_truthy({result})",
                "??": f"js_nullish({result})",
            }[node["operator"]]
            self.line(f"if ({condition}) {{")
            right = self.expr(node["right"])
            self.line(f"{result} = {right};")
            self.line("}")
            return result
        if kind == "ConditionalExpression":
            condition = self.expr(node["test"])
            result = self.value("js_undefined")
            self.line(f"if (js_truthy({condition})) {{")
            value = self.expr(node["consequent"])
            self.line(f"{result} = {value};")
            self.line("} else {")
            value = self.expr(node["alternate"])
            self.line(f"{result} = {value};")
            self.line("}")
            return result
        if kind == "AssignmentExpression":
            read, write = self.reference(node["left"])
            operator = node["operator"]
            if operator == "=":
                return self.value(write.format(value=self.expr(node["right"])))
            left = self.value(read)
            if operator in ("&&=", "||=", "??="):
                self.fail(node)
            right = self.expr(node["right"])
            result = self.value(
                f"js_binary({c_string(operator[:-1])}, {left}, {right})"
            )
            return self.value(write.format(value=result))
        if kind == "UpdateExpression":
            read, write = self.reference(node["argument"])
            old = self.value(f"js_number(js_to_number({read}))")
            delta = 1 if node["operator"] == "++" else -1
            value = self.value(f"js_number({old}.number + {delta})")
            self.line(write.format(value=value) + ";")
            return value if node["prefix"] else old
        self.fail(node)

    def block(self, nodes):
        for node in nodes:
            if node["type"] == "FunctionDeclaration":
                self.statement(node)
        for node in nodes:
            if node["type"] != "FunctionDeclaration":
                self.statement(node)

    def bind(self, pattern, value):
        if pattern["type"] != "Identifier":
            self.fail(pattern)
        self.line(f'js_define({self.scope}, {c_string(pattern["name"])}, {value});')

    def statement(self, node):
        kind = node["type"]
        if kind == "BlockStatement":
            parent, self.scope = self.scope, self.fresh("scope")
            self.line(
                f"{{ JsScope *{self.scope} = js_scope({parent}); (void){self.scope};"
            )
            self.block(node["body"])
            self.line("}")
            self.scope = parent
        elif kind == "VariableDeclaration":
            for decl in node["declarations"]:
                self.bind(decl["id"], self.expr(decl["init"]))
        elif kind == "FunctionDeclaration":
            self.bind(node["id"], self.function(node))
        elif kind == "ClassDeclaration":
            base = self.expr(node["superClass"])
            cls = self.value(f"js_class({base})")
            for method in node["body"]["body"]:
                if (
                    method["type"] != "MethodDefinition"
                    or method["kind"] != "method"
                    or method["computed"]
                    or method["static"]
                ):
                    self.fail(method)
                value = self.function(method["value"])
                self.line(f'js_set({cls}, {c_string(method["key"]["name"])}, {value});')
            self.bind(node["id"], cls)
        elif kind == "ExpressionStatement":
            value = self.expr(node["expression"])
            self.line(f"(void){value};")
        elif kind == "ReturnStatement":
            result = self.expr(node["argument"])
            self.line(f"return {result};")
        elif kind == "IfStatement":
            condition = self.expr(node["test"])
            self.line(f"if (js_truthy({condition})) {{")
            self.statement(node["consequent"])
            if node["alternate"]:
                self.line("} else {")
                self.statement(node["alternate"])
            self.line("}")
        elif kind == "ForOfStatement":
            if node["await"] or node["left"]["type"] != "VariableDeclaration":
                self.fail(node)
            collection = self.expr(node["right"])
            index = self.fresh("index")
            parent, self.scope = self.scope, self.fresh("scope")
            self.line(
                f"for (size_t {index} = 0; {index} < js_length({collection}); {index}++) {{"
            )
            self.line(f"JsScope *{self.scope} = js_scope({parent});")
            self.bind(
                node["left"]["declarations"][0]["id"],
                f"js_index({collection}, {index})",
            )
            self.continues.append("continue;")
            self.statement(node["body"])
            self.continues.pop()
            self.line("}")
            self.scope = parent
        elif kind in ("ForStatement", "WhileStatement"):
            parent, self.scope = self.scope, self.fresh("scope")
            self.line(
                f"{{ JsScope *{self.scope} = js_scope({parent}); (void){self.scope};"
            )
            if node.get("init"):
                self.statement(
                    node["init"]
                    if node["init"]["type"] == "VariableDeclaration"
                    else {"type": "ExpressionStatement", "expression": node["init"]}
                )
            self.line("while (true) {")
            if node.get("test"):
                condition = self.expr(node["test"])
                self.line(f"if (!js_truthy({condition})) break;")
            update = self.fresh("update") if node.get("update") else None
            if update:
                self.line(f"if (false) goto {update};")
            self.continues.append(f"goto {update};" if update else "continue;")
            self.statement(node["body"])
            self.continues.pop()
            if update:
                self.line(f"{update}: ;")
                result = self.expr(node["update"])
                self.line(f"(void){result};")
            self.line("}}")
            self.scope = parent
        elif kind in ("BreakStatement", "ContinueStatement") and not node.get("label"):
            self.line("break;" if kind == "BreakStatement" else self.continues[-1])
        elif kind != "EmptyStatement":
            self.fail(node)

    def compile(self, ast):
        self.block(ast["body"])
        body = "\n".join(self.lines)
        return "\n\n".join(
            [
                *self.functions,
                f"static void {self.name}(JsScope *scope) {{\n(void)scope;\n{body}\n}}",
            ]
        )


def compile_script(source, path, name="htgcScript"):
    return CEmitter(path, name).compile(parse(source, path))
