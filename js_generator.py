"""Lower suspension points to Dart sync* continuations, not an AST interpreter."""
from js_dart import Compiler, quote


class GeneratorCompiler(Compiler):
    def __init__(self, parent):
        super().__init__(parent.path)
        self.serial, self.scope, self.receiver = parent.serial, parent.scope, parent.receiver
        self.module_owner = parent.module_owner
        self.script_name = parent.script_name
        self.private_names = parent.private_names
        self.active, self.prelude = False, []

    def capture(self, callback):
        outer, self.prelude = self.prelude, []
        result = callback()
        prefix, self.prelude = '\n'.join(self.prelude), outer
        return prefix, result

    def save(self, expression):
        temp = self.name('gvalue')
        self.prelude.append(f'final {temp} = {expression};')
        return temp

    def function(self, node):
        active, self.active = self.active, False
        try:
            return super().function(node)
        finally:
            self.active = active

    def member_value(self, node, call=False, optional_call=False):
        if node['object']['type'] == 'Super':
            if self.home is None:
                self.fail(node, "super outside a class method")
            key = self.key(node)
            operation = (f'jSuperCallSite({self.receiver}, {self.home}, {key}, optional: {str(optional_call).lower()})'
                         if call else f'jSuperReference({self.receiver}, {self.home}, {key}).read()')
            return self.save(operation)
        obj = self.expr(node['object'])
        prefix, key = self.capture(lambda: self.key(node))
        temp = self.name('gmember')
        test = f'identical({obj}, jShortCircuit)'
        if node.get('optional'):
            test += f' || jNullish({obj})'
        if node['property']['type'] == 'PrivateIdentifier':
            private = self.private_name(node['property'])
            value = f'{private}.callSite({obj}, optional: {str(optional_call).lower()})' if call else f'{private}.read({obj})'
        else:
            value = f'JCallSite.member({obj}, {key}, optionalCall: {str(optional_call).lower()})' if call else f'jGet({obj}, {key})'
        missing = 'JCallSite(jShortCircuit)' if call else 'jShortCircuit'
        self.prelude.append(f'dynamic {temp};\nif ({test}) {{ {temp} = {missing}; }} else {{\n{prefix}\n{temp} = {value};\n}}')
        return temp

    def arguments(self, arguments):
        values = self.name('gargs')
        self.prelude.append(f'final {values} = <dynamic>[];')
        for arg in arguments:
            if arg['type'] == 'SpreadElement':
                value = self.expr(arg['argument'])
                self.prelude.append(f'{values}.addAll(jIterable({value}));')
            else:
                value = self.expr(arg)
                self.prelude.append(f'{values}.add({value});')
        return values

    def bind(self, pattern, value, kind='let'):
        if not self.active or pattern['type'] == 'Identifier':
            return super().bind(pattern, value, kind)
        if pattern['type'] == 'AssignmentPattern':
            temp = self.name('gdefault')
            prefix, default = self.capture(lambda: self.expr(pattern['right']))
            return (f'dynamic {temp} = {value};\nif (identical({temp}, jUndefined)) {{\n{prefix}\n{temp} = {default};\n}}\n'
                    + self.bind(pattern['left'], temp, kind))
        if pattern['type'] == 'ObjectPattern':
            temp, keys = self.name('gobject'), self.name('gkeys')
            code = f'final {temp} = jRequireCoercible({value});\nfinal {keys} = <Object>[];\n'
            for prop in pattern['properties']:
                if prop['type'] == 'RestElement':
                    code += self.bind(prop['argument'], f'jCopyProperties({temp}, excluding: {keys})', kind) + '\n'
                else:
                    prefix, expression = self.capture(lambda: self.property_key(prop))
                    key = self.name('gkey')
                    code += f'{prefix}\nfinal {key} = jPropertyKey({expression});\n{keys}.add({key});\n'
                    code += self.bind(prop['value'], f'jGet({temp}, {key})', kind) + '\n'
            return code
        # The base array pattern owns IteratorClose; recursive default bindings
        # above keep suspension inside the appropriate branch and try/finally.
        return super().bind(pattern, value, kind)

    def expr(self, node):
        if not self.active:
            return super().expr(node)
        if node is None:
            return 'jUndefined'
        kind = node['type']
        if kind == 'HTGCRaw':
            return node['value']
        if kind in ('YieldExpression', 'AwaitExpression'):
            value = self.expr(node.get('argument'))
            if kind == 'YieldExpression' and node.get('delegate'):
                self.prelude.append(f'yield* jYieldDelegate({self.generator}, {value});')
                return self.save(f'{self.generator}.delegated')
            self.prelude.append(f'yield JGeneratorStep({value}, awaited: {str(kind == "AwaitExpression").lower()});')
            return self.save(f'{self.generator}.resume()')
        if kind == 'TaggedTemplateExpression':
            tag = node['tag']
            callee = self.member_value(tag, True) if tag['type'] == 'MemberExpression' else self.save(f'JCallSite({self.expr(tag)})')
            strings = self.save(self.template_object(node))
            substitutions = [self.expr(value) for value in node['quasi']['expressions']]
            return self.save(f'{callee}.call(<dynamic>[{", ".join([strings, *substitutions])}])')
        if kind == 'MemberExpression':
            return self.member_value(node)
        if kind in ('CallExpression', 'NewExpression'):
            if "htgcLoweredRegExp" in node:
                callee = self.expr(node["callee"])
                return self.save(self.precompiled_regexp(node, callee, self.arguments(node["arguments"])))
            callee = node['callee']
            if kind == 'NewExpression':
                target = self.expr(callee)
                return self.save(f'jNew({target}, {self.arguments(node["arguments"])})')
            target = self.member_value(callee, True, node.get('optional', False)) if callee['type'] == 'MemberExpression' else self.save(f'JCallSite({self.expr(callee)}, optional: {str(node.get("optional", False)).lower()})')
            prefix, args = self.capture(lambda: self.arguments(node['arguments']))
            temp = self.name('gcall')
            self.prelude.append(f'dynamic {temp};\nif ({target}.skipped) {{ {temp} = jShortCircuit; }} else {{\n{prefix}\n{temp} = {target}.call({args});\n}}')
            return temp
        if kind in ('LogicalExpression', 'ConditionalExpression'):
            left = self.expr(node['left'] if kind == 'LogicalExpression' else node['test'])
            if kind == 'ConditionalExpression':
                yes, yvalue = self.capture(lambda: self.expr(node['consequent']))
                no, nvalue = self.capture(lambda: self.expr(node['alternate']))
                test = f'jTruthy({left})'
            else:
                yes, yvalue = self.capture(lambda: self.expr(node['right']))
                no, nvalue = '', left
                op = node['operator']
                test = f'jNullish({left})' if op == '??' else f'{"!" if op == "||" else ""}jTruthy({left})'
            temp = self.name('gconditional')
            self.prelude.append(f'dynamic {temp};\nif ({test}) {{\n{yes}\n{temp} = {yvalue};\n}} else {{\n{no}\n{temp} = {nvalue};\n}}')
            return temp
        if kind == 'AssignmentExpression':
            if node['left']['type'] in ('ArrayPattern', 'ObjectPattern'):
                value = self.expr(node['right'])
                prefix, assignment = self.capture(lambda: self.bind(node['left'], value, 'assign'))
                self.prelude.append(f'{{\n{prefix}\n{assignment}\n}}')
                return value
            assignment = self.save(f'JAssignment({self.ref(node["left"])}, {quote(node["operator"])})')
            prefix, value = self.capture(lambda: self.expr(node['right']))
            temp = self.name('gassigned')
            self.prelude.append(f'dynamic {temp};\nif ({assignment}.skip) {{ {temp} = {assignment}.left; }} else {{\n{prefix}\n{temp} = {assignment}.assign({value});\n}}')
            return temp
        if kind == 'ArrayExpression':
            result = self.name('garray')
            self.prelude.append(f'final {result} = <dynamic>[];')
            for item in node['elements']:
                value = '_jHole' if item is None else self.expr(item['argument'] if item['type'] == 'SpreadElement' else item)
                self.prelude.append(f'{result}.addAll(jIterable({value}));' if item and item['type'] == 'SpreadElement' else f'{result}.add({value});')
            return result
        if kind == 'ObjectExpression':
            result = self.name('gobject')
            self.prelude.append(f'final {result} = JObject();')
            for prop in node['properties']:
                if prop['type'] == 'SpreadElement':
                    value = self.expr(prop['argument'])
                    self.prelude.append(f'for (final _entry in jObjectSpread({value})) {{ jApplyObjectEntry({result}, _entry); }}')
                else:
                    key = self.save(f'jPropertyKey({self.property_key(prop)})')
                    value = self.expr(prop['value'])
                    mode = prop.get('kind', 'init')
                    if not prop.get('computed') and not prop.get('method') and not prop.get('shorthand') and mode == 'init' and prop['key'].get('name', prop['key'].get('value')) == '__proto__':
                        mode = 'prototype'
                    self.prelude.append(f'jApplyObjectEntry({result}, ({quote(mode)}, {key}, {value}));')
            return result
        if kind == 'TemplateLiteral':
            parts = []
            for i, item in enumerate(node['quasis']):
                parts.append(quote(item['value']['cooked']))
                if i < len(node['expressions']):
                    parts.append(self.save(f'jString({self.expr(node["expressions"][i])})'))
            return self.save(' + '.join(parts))
        return self.save(super().expr(node))

    def stmt(self, node):
        if not self.active:
            return super().stmt(node)
        prefix, body = self.capture(lambda: self.statement(node))
        return prefix + '\n' + body

    def statement(self, node):
        kind = node['type']
        if kind == 'ReturnStatement' and self.generator_async:
            value = self.expr({'type': 'AwaitExpression', 'argument': node.get('argument')})
            return f'throw JAsyncReturn({value});'
        if kind == 'VariableDeclaration':
            code = []
            for declaration in node['declarations']:
                if node['kind'] == 'var' and declaration.get('init') is None:
                    continue
                prefix, value = self.capture(lambda: self.expr(declaration.get('init')))
                binding_prefix, binding = self.capture(lambda: self.bind(declaration['id'], value, node['kind']))
                code += [prefix, binding_prefix, binding]
            return '\n'.join(code)
        if kind == 'ForOfStatement':
            asynchronous = node.get('await', False)
            source = self.expr(node['right'])
            record, item = self.name('giterator'), self.name('gitem')
            parent, self.scope = self.scope, self.name('gscope')
            left = node['left']
            prefix, init = self.capture(lambda: self.loop_binding(left, item))
            body = self.stmt(node['body'])
            scope, self.scope = self.scope, parent
            factory = 'jGetAsyncIterator' if asynchronous else 'jGetIterator'
            def wait(expression):
                return f'yield JGeneratorStep({expression}, awaited: true);\n{self.generator}.resume();' if asynchronous else f'{expression};'
            advance = f'yield JGeneratorStep({record}.advance(), awaited: true);\nif (!jTruthy({self.generator}.resume())) break;' if asynchronous else f'if (!{record}.advance()) break;'
            return (f'{{ final {record} = {factory}({source});\ntry {{\n{self.loop_label(node)}while (true) {{\n{advance}\n'
                    f'final {item} = {record}.current;\nfinal {scope} = JScope({parent});\n{prefix}\n{init}\n{body}\n}}\n'
                    f'}} catch (_error) {{\n{wait(f"{record}.close(suppressErrors: _error is! JAsyncReturn)")}\nrethrow;\n}} finally {{\n{wait(f"{record}.close()")}\n}}\n}}')
        if kind == 'IfStatement':
            condition = self.expr(node['test'])
            return f'if (jTruthy({condition})) {{\n{self.stmt(node["consequent"])}\n}}' + (f' else {{\n{self.stmt(node["alternate"])}\n}}' if node.get('alternate') else '')
        if kind in ('ForStatement', 'WhileStatement', 'DoWhileStatement'):
            parent, self.scope = self.scope, self.name('gscope')
            initial = ''
            if kind == 'ForStatement' and node.get('init'):
                initial = self.stmt(node['init']) if node['init']['type'] == 'VariableDeclaration' else self.stmt({'type':'ExpressionStatement','expression':node['init']})
            update_prefix, update = self.capture(lambda: self.expr(node.get('update')))
            test_prefix, condition = self.capture(lambda: self.expr(node.get('test')) if node.get('test') else 'true')
            body = self.stmt(node['body'])
            first = self.name('gfirst')
            if kind == 'DoWhileStatement':
                loop = f'if (!{first}) {{\n{test_prefix}\nif (!jTruthy({condition})) break;\n}}\n{first} = false;\n{body}'
            else:
                loop = f'if (!{first}) {{\n{update_prefix}\n{update};\n}}\n{first} = false;\n{test_prefix}\nif (!jTruthy({condition})) break;\n{body}'
            scope = self.scope
            self.scope = parent
            return f'{{\nfinal {scope} = JScope({parent});\n{initial}\nvar {first} = true;\n{self.loop_label(node)}while (true) {{\n{loop}\n}}\n}}'
        if kind == 'SwitchStatement':
            # Case tests can suspend, and are evaluated only until a match.
            import copy
            replacement = copy.deepcopy(node)
            value = self.expr(node['discriminant'])
            selected = self.name('gselected')
            self.prelude.append(f'var {selected} = -1;')
            default = -1
            for i, case in enumerate(node['cases']):
                if case['test'] is None:
                    default = i
                else:
                    prefix, test = self.capture(lambda: self.expr(case['test']))
                    self.prelude.append(f'if ({selected} < 0) {{\n{prefix}\nif (jStrictEqual({value},{test})) {selected} = {i};\n}}')
                replacement['cases'][i]['test'] = {'type':'Literal','value':i}
            self.prelude.append(f'if ({selected} < 0) {selected} = {default};')
            replacement['discriminant'] = {'type':'HTGCRaw','value':selected}
            active,self.active=self.active,False
            # Base switch owns lexical scope and fall-through labels; body
            # statements must still be compiled with suspension enabled.
            self.active=active
            return super().switch(replacement)
        return super().stmt(node)


def compile_generator(parent, node):
    compiler = GeneratorCompiler(parent)
    compiler.generator_async = node.get('async', False)
    compiler.home = node.get('htgc_home')
    outer, args, receiver = compiler.scope, compiler.name('ga'), compiler.name('gthis')
    compiler.scope, compiler.generator = compiler.name('gs'), compiler.name('generator')
    compiler.receiver = receiver
    setup = [
        f'final {compiler.scope} = JScope({outer});',
        f'{compiler.scope}.define("arguments", jArgumentsObject({args}));',
    ]
    for i, param in enumerate(node['params']):
        value = f'jArg({args},{i})'
        if param['type'] == 'RestElement':
            value, param = f'{args}.skip({i}).toList()', param['argument']
        if param['type'] == 'AssignmentPattern':
            value = f'jDefault({value}, () => {compiler.expr(param["right"])})'
            param = param['left']
        setup.append(compiler.bind(param, value))
    compiler.active, compiler.asynchronous = True, True
    body = compiler.block_contents(node['body']['body'], hoist_vars=True)
    parent.serial = compiler.serial
    return (f'jGeneratorFunction(({args}, {receiver}) {{\n' + '\n'.join(setup)
            + f'\nreturn JGenerator(({compiler.generator}) sync* {{\n{compiler.temp_declarations()}\ntry {{\n{body}\n'
            + '\nyield JGeneratorStep(jUndefined, done: true);\n} on JAsyncReturn catch (_return) {\nyield JGeneratorStep(_return.value, done: true);\n}\n}'
            + f', asynchronous: {str(node.get("async", False)).lower()});\n}}, asynchronous: {str(node.get("async", False)).lower()})')
