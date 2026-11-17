"""Link local ECMAScript source modules and emit their Dart initializers."""

from dataclasses import dataclass, field
from urllib.parse import urlsplit

from js_dart import Compiler, parse, quote


@dataclass
class Module:
    compiler: Compiler
    name: str
    dependencies: dict = field(default_factory=dict)
    imports: dict = field(default_factory=dict)
    exports: dict = field(default_factory=dict)
    stars: list = field(default_factory=list)
    statements: list = field(default_factory=list)
    json_source: str | None = None


AMBIGUOUS = object()
DEFAULT = "*default*"


def identifier(node):
    return node["name"] if node["type"] == "Identifier" else node["value"]


class DartModules:
    def __init__(self):
        self.modules = {}

    def entry(self, source, owner, root, read, local, name, *, inline=False):
        module_id = owner.relative_to(root).as_posix()
        key = f"{module_id}#{name}" if inline else module_id
        self.add(source, key, owner, root, read, local)
        return (
            f"void {name}(JScope scope) {{\n"
            f"  scope.modules(htgcModules).evaluate({quote(key)}).observe((_) {{}},\n"
            "    (error) => Zone.current.handleUncaughtError(JThrown(error), StackTrace.current));\n"
            "}\n"
        )

    def collect_dynamic(self, ast, owner, root, read, local):
        if isinstance(ast, list):
            for child in ast:
                self.collect_dynamic(child, owner, root, read, local)
        elif isinstance(ast, dict):
            if ast.get("type") == "ImportExpression":
                source = ast["source"]
                specifier = source.get("value") if source["type"] == "Literal" else None
                if isinstance(specifier, str):
                    url = urlsplit(specifier)
                    if (specifier.startswith(("./", "../", "/")) and
                        not (url.scheme or url.netloc or url.query or url.fragment)):
                        path = local(specifier, owner)
                        # Missing dynamic imports reject at runtime, like host loading.
                        if path.is_file():
                            key = path.relative_to(root).as_posix()
                            self.add(read(path), key, path, root, read, local, json_module=path.suffix == ".json")
            for child in ast.values():
                self.collect_dynamic(child, owner, root, read, local)

    def script(self, source, owner, root, read, local, name):
        key = owner.relative_to(root).as_posix()
        compiler = Compiler(key)
        compiler.module_owner = key
        ast = parse(source, key)
        self.collect_dynamic(ast, owner, root, read, local)
        return compiler.compile(ast, name)

    def add(self, source, key, owner, root, read, local, *, json_module=False):
        if key in self.modules:
            return
        module = self.modules[key] = Module(Compiler(key), f"htgcModule{len(self.modules)}")
        module.compiler.module_owner = owner.relative_to(root).as_posix()
        module.compiler.module_key = key
        if json_module:
            module.json_source = source
            module.exports["default"] = (None, DEFAULT)
            return
        ast = parse(source, key)
        module.compiler.collect_constructor_aliases(ast)
        for node in ast["body"]:
            kind = node["type"]
            reference = node.get("source")
            target = None
            if reference is not None:
                specifier = reference["value"]
                url = urlsplit(specifier)
                if (
                    not specifier.startswith(("./", "../", "/"))
                    or url.netloc or url.scheme or url.query or url.fragment
                ):
                    module.compiler.fail(node, f"ローカルの静的モジュール指定子 {specifier!r}")
                path = local(specifier, owner)
                target = path.relative_to(root).as_posix()
                attributes = {
                    identifier(entry["key"]): entry["value"]["value"]
                    for entry in node.get("attributes", [])
                }
                json_target = path.suffix == ".json"
                if attributes != ({"type": "json"} if json_target else {}):
                    module.compiler.fail(node, f"モジュールの import 属性 {specifier!r}")
                if target not in self.modules:
                    self.add(read(path), target, path, root, read, local, json_module=json_target)
                module.dependencies[target] = None
            if kind == "ImportDeclaration":
                for specifier in node["specifiers"]:
                    remote = {
                        "ImportDefaultSpecifier": "default",
                        "ImportNamespaceSpecifier": None,
                    }.get(specifier["type"])
                    if specifier["type"] == "ImportSpecifier":
                        remote = identifier(specifier["imported"])
                    module.imports[identifier(specifier["local"])] = (target, remote)
            elif kind == "ExportAllDeclaration":
                if node.get("exported") is None:
                    module.stars.append(target)
                else:
                    module.exports[identifier(node["exported"])] = (target, None)
            elif kind == "ExportNamedDeclaration":
                declaration = node["declaration"]
                if declaration is not None:
                    module.statements.append(declaration)
                    names = (
                        (name for entry in declaration["declarations"]
                         for name in module.compiler.binding_names(entry["id"]))
                        if declaration["type"] == "VariableDeclaration"
                        else [identifier(declaration["id"])]
                    )
                    for exported in names:
                        module.exports[exported] = (None, exported)
                for specifier in node["specifiers"]:
                    module.exports[identifier(specifier["exported"])] = (
                        target, identifier(specifier["local"]),
                    )
            elif kind == "ExportDefaultDeclaration":
                declaration = node["declaration"]
                if declaration["type"] in ("FunctionDeclaration", "ClassDeclaration"):
                    if declaration["id"] is None:
                        declaration["id"] = {"type": "Identifier", "name": DEFAULT}
                    name = identifier(declaration["id"])
                    module.statements.append(declaration)
                else:
                    name = DEFAULT
                    module.statements.append({
                        "type": "VariableDeclaration", "kind": "const",
                        "declarations": [{
                            "id": {"type": "Identifier", "name": name},
                            "init": declaration,
                        }],
                    })
                module.exports["default"] = (None, name)
            else:
                module.statements.append(node)
        self.collect_dynamic(ast, owner, root, read, local)

    def export_names(self, key, seen):
        if key in seen:
            return set()
        seen.add(key)
        module = self.modules[key]
        names = set(module.exports)
        for dependency in module.stars:
            names.update(self.export_names(dependency, seen) - {"default"})
        return names

    def resolve(self, key, name, seen=frozenset()):
        if name is None:
            return key, None
        if (key, name) in seen:
            return None
        seen = seen | {(key, name)}
        module = self.modules[key]
        if name in module.exports:
            target, remote = module.exports[name]
            if target is not None:
                return self.resolve(target, remote, seen)
            if remote in module.imports:
                return self.resolve(*module.imports[remote], seen)
            return key, remote
        if name == "default":
            return None
        binding = None
        for dependency in module.stars:
            result = self.resolve(dependency, name, seen)
            if result is AMBIGUOUS or (result is not None and binding not in (None, result)):
                return AMBIGUOUS
            if result is not None:
                binding = result
        return binding

    def checked_binding(self, module, target, name):
        binding = self.resolve(target, name)
        if binding is None or binding is AMBIGUOUS:
            reason = "曖昧なエクスポート" if binding is AMBIGUOUS else "エクスポートが見つかりません"
            module.compiler.fail({}, f"{reason}: {target} ({name})")
        return binding

    def emit(self):
        functions = []
        definitions = []

        def bindings(entries):
            return "{" + ", ".join(
                f"{quote(name)}: ({quote(target)}, {quote(remote) if remote is not None else 'null'})"
                for name, (target, remote) in entries.items()
            ) + "}"

        for key, module in self.modules.items():
            compiler = module.compiler
            nodes = module.statements
            compiler.asynchronous = compiler.has_await(nodes)
            declarations = [node for node in nodes if node["type"] == "FunctionDeclaration"]
            initialize = [compiler.stmt(node) for node in declarations]
            initialize.extend(
                f"scope.declareVar({quote(name)});"
                for name in dict.fromkeys(compiler.var_names(nodes))
            )
            executable = []
            for node in nodes:
                kind = node["type"]
                if kind == "FunctionDeclaration":
                    continue
                if kind == "VariableDeclaration" and node["kind"] != "var":
                    for entry in node["declarations"]:
                        for name in compiler.binding_names(entry["id"]):
                            initialize.append(f"scope.reserve({quote(name)});")
                elif kind == "ClassDeclaration":
                    initialize.append(f"scope.reserve({quote(identifier(node['id']))});")
                executable.append(node)
            execute = compiler.resource_region(
                executable, lambda: "\n".join(compiler.stmt(node) for node in executable)
            )
            if module.json_source is not None:
                initialize.append(f"scope.reserve({quote(DEFAULT)});")
                execute = f"scope.define({quote(DEFAULT)}, jJSONParse({quote(module.json_source)}, jUndefined), constant: true);"
            functions.extend([
                f"void {module.name}Init(JScope scope) {{\n" + "\n".join(initialize) + "\n}",
                f"dynamic {module.name}Body(JScope scope) {{\n" + (
                    "return " + compiler.async_body(
                        compiler.temp_declarations() + execute
                        + "\nthrow JAsyncReturn(jUndefined);"
                    ) + ";" if compiler.asynchronous else
                    compiler.temp_declarations() + execute + "\nreturn jUndefined;"
                ) + "\n}",
            ])
            imports = {
                local: self.checked_binding(module, *binding)
                for local, binding in module.imports.items()
            }
            exports = {
                name: self.checked_binding(module, key, name)
                for name in module.exports
            }
            for name in sorted(self.export_names(key, set()) - exports.keys()):
                binding = self.resolve(key, name)
                if binding is not None and binding is not AMBIGUOUS:
                    exports[name] = binding
            dependencies = ", ".join(quote(target) for target in module.dependencies)
            definitions.append(
                f"  {quote(key)}: JModuleDefinition([{dependencies}], "
                f"{bindings(imports)}, {bindings(dict(sorted(exports.items())))}, "
                f"{module.name}Init, {module.name}Body, hasAwait: {str(compiler.asynchronous).lower()}, "
                f"json: {str(module.json_source is not None).lower()}),"
            )
        return "\n" + "\n".join([
            *functions, "const htgcModules = <String, JModuleDefinition>{", *definitions, "};", "",
        ])
