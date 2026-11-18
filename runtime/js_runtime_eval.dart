part of 'js_core.dart';

/*
Expression parsing follows the assignment/conditional precedence structure in
Acorn (parseMaybeAssign / parseMaybeConditional / parseExprOp). Reimplemented
in Dart with HTGC runtime references and deferred evaluation.
Source: https://github.com/acornjs/acorn (installed version below in notices).

MIT License

Copyright (C) 2012-2022 by various contributors (see AUTHORS)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

// A deliberately small runtime parser. Parse the complete input before running
// any expression so unsupported syntax cannot cause partial side effects.
final _jRuntimeEmpty = Object();

typedef _EvalRead = dynamic Function();

class _EvalExpr {
  final _EvalRead read;
  final dynamic Function(dynamic)? write;
  final JRef Function()? reference;
  final JCallSite Function()? callSite;
  _EvalExpr(this.read, [this.write, this.reference, this.callSite]);
}

class _RuntimeLexicalScope {
  JScope current;
  _RuntimeLexicalScope(this.current);
}

class _RuntimeEvalParser {
  final String source;
  _RuntimeLexicalScope scope;
  int loopDepth = 0;
  final dynamic thisValue;
  final bool functionBody;
  final List<String> tokens = [];
  final lineBreaks = <int>{};
  bool strictFunction = false;
  int at = 0;
  Set<String> lexicalNames = <String>{};
  _RuntimeEvalParser(
    this.source,
    JScope scope,
    this.thisValue, {
    this.functionBody = false,
  }) : scope = _RuntimeLexicalScope(scope) {
    final token = RegExp(
      r'''\s+|(?:[A-Za-z_$][A-Za-z0-9_$]*)|(?:\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)|(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?:>>>=|<<=|>>=|\*\*=|&&=|\|\|=|\?\?=|%=|&=|\|=|\^=|===|!==|>>>|\*\*|==|!=|<=|>=|&&|\|\||\?\?|<<|>>|\+\+|--|\+=|-=|\*=|/=|=>)|[{}()\[\].,:?&|^+\-*/%<>=!~;]''',
    );
    var pos = 0;
    while (pos < source.length) {
      final match = token.matchAsPrefix(source, pos);
      if (match == null) _unsupported();
      final word = match.group(0)!;
      if (word.trim().isNotEmpty) {
        tokens.add(word);
      } else if (RegExp(r'[\n\r\u2028\u2029]').hasMatch(word)) {
        lineBreaks.add(tokens.length);
      }
      pos = match.end;
    }
    tokens.add('');
  }
  Never _unsupported() => throw JThrown(
    JError('SyntaxError', 'Unsupported or invalid runtime eval syntax'),
  );
  String get peek => tokens[at];
  bool take(String value) {
    if (peek != value) return false;
    at++;
    return true;
  }

  void expect(String value) {
    if (!take(value)) _unsupported();
  }

  static const precedence = <String, int>{
    '??': 1,
    '||': 1,
    '&&': 2,
    '|': 3,
    '^': 4,
    '&': 5,
    '==': 6,
    '!=': 6,
    '===': 6,
    '!==': 6,
    '<': 7,
    '>': 7,
    '<=': 7,
    '>=': 7,
    '<<': 8,
    '>>': 8,
    '>>>': 8,
    '+': 9,
    '-': 9,
    '*': 10,
    '/': 10,
    '%': 10,
    '**': 11,
  };
  static const assignments = {
    '=',
    '+=',
    '-=',
    '*=',
    '/=',
    '%=',
    '**=',
    '<<=',
    '>>=',
    '>>>=',
    '&=',
    '|=',
    '^=',
    '&&=',
    '||=',
    '??=',
  };
  List<_EvalRead> parse({bool inBlock = false}) {
    final statements = <_EvalRead>[];
    var directives = functionBody && !inBlock;
    while (peek.isNotEmpty && !(inBlock && peek == '}')) {
      final start = at;
      statements.add(statement());
      if (directives) {
        final first = tokens[start];
        directives =
            (at == start + 1 ||
                (at == start + 2 && tokens[start + 1] == ';')) &&
            (first.startsWith('"') || first.startsWith("'"));
        if (directives &&
            (first == '"use strict"' || first == "'use strict'")) {
          strictFunction = true;
        }
      }
    }
    return statements;
  }

  _EvalRead statement({bool allowLexical = true}) {
    if (take(';')) return () => _jRuntimeEmpty;
    if (peek == '{') return block();
    if (take('for')) {
      expect('(');
      final start = peek == ';' ? null : expression();
      expect(';');
      final condition = peek == ';' ? _EvalExpr(() => true) : expression();
      expect(';');
      final update = peek == ')' ? null : expression();
      expect(')');
      final body = loopBody();
      return () {
        start?.read();
        return runLoop(condition, body, update: update);
      };
    }
    if (take('while')) {
      expect('(');
      final condition = expression();
      expect(')');
      final body = loopBody();
      return () => runLoop(condition, body);
    }
    if (take('do')) {
      final body = loopBody();
      expect('while');
      expect('(');
      final condition = expression();
      expect(')');
      take(';');
      return () => runLoop(condition, body, first: true);
    }
    if (take('try')) {
      final body = block();
      if (take('catch')) {
        if (take('(')) {
          final name = peek;
          if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name) ||
              !_runtimeBindingName(name))
            _unsupported();
          at++;
          expect(')');
          final parent = scope;
          final binding = _RuntimeLexicalScope(parent.current);
          scope = binding;
          late final _EvalRead catchBody;
          try {
            catchBody = block(forbiddenName: name);
          } finally {
            scope = parent;
          }
          return finishTry(body, (error) {
            binding.current = JScope(parent.current)..define(name, error);
            return catchBody();
          });
        }
        final catchBody = block();
        return finishTry(body, (_) => catchBody());
      }
      return finishTry(body, null);
    }
    if (take('if')) {
      expect('(');
      final condition = expression();
      expect(')');
      final yes = statement(allowLexical: false);
      final no = take('else') ? statement(allowLexical: false) : null;
      return () {
        try {
          final value = jTruthy(condition.read())
              ? yes()
              : (no == null ? jUndefined : no());
          return identical(value, _jRuntimeEmpty) ? jUndefined : value;
        } on _RuntimeJump catch (jump) {
          jump.updateEmpty(jUndefined);
          rethrow;
        }
      };
    }
    final simple = simpleStatement(allowLexical);
    if (!take(';') &&
        peek.isNotEmpty &&
        peek != '}' &&
        !lineBreaks.contains(at))
      _unsupported();
    return simple;
  }

  _EvalRead block({String? forbiddenName}) {
    expect('{');
    final parent = scope;
    final parentNames = lexicalNames;
    final blockScope = _RuntimeLexicalScope(parent.current);
    final blockNames = <String>{};
    scope = blockScope;
    lexicalNames = blockNames;
    try {
      final statements = parse(inBlock: true);
      expect('}');
      if (blockNames.contains(forbiddenName)) _unsupported();
      return () {
        final local = JScope(parent.current);
        blockScope.current = local;
        for (final name in blockNames) local.reserve(name);
        return _runRuntimeStatements(statements, initial: _jRuntimeEmpty);
      };
    } finally {
      scope = parent;
      lexicalNames = parentNames;
    }
  }

  _EvalRead loopBody() {
    loopDepth++;
    try {
      return statement(allowLexical: false);
    } finally {
      loopDepth--;
    }
  }

  dynamic runLoop(
    _EvalExpr condition,
    _EvalRead body, {
    bool first = false,
    _EvalExpr? update,
  }) {
    dynamic result = jUndefined;
    while (first || jTruthy(condition.read())) {
      first = false;
      try {
        final value = body();
        if (!identical(value, _jRuntimeEmpty)) result = value;
      } on _RuntimeJump catch (jump) {
        if (!identical(jump.value, _jRuntimeEmpty)) result = jump.value;
        if (jump.isBreak) break;
      }
      update?.read();
    }
    return result;
  }

  _EvalRead finishTry(_EvalRead body, dynamic Function(dynamic)? handler) {
    final cleanup = take('finally') ? block() : null;
    if (handler == null && cleanup == null) _unsupported();
    return () {
      dynamic value;
      try {
        try {
          value = body();
        } on JThrown catch (error) {
          if (handler == null) rethrow;
          value = handler(error.value);
        } finally {
          cleanup?.call();
        }
      } on _RuntimeJump catch (jump) {
        jump.updateEmpty(jUndefined);
        rethrow;
      }
      return identical(value, _jRuntimeEmpty) ? jUndefined : value;
    };
  }

  _EvalRead simpleStatement(bool allowLexical) {
    if (peek == 'break' || peek == 'continue') {
      if (loopDepth == 0) _unsupported();
      final isBreak = tokens[at++] == 'break';
      return () => throw _RuntimeJump(isBreak);
    }
    if (take('return')) {
      if (!functionBody) _unsupported();
      final value =
          peek.isEmpty || peek == ';' || peek == '}' || lineBreaks.contains(at)
          ? _EvalExpr(() => jUndefined)
          : expression();
      return () => throw _RuntimeReturn(value.read());
    }
    if (take('throw')) {
      if (lineBreaks.contains(at)) _unsupported();
      final value = expression();
      return () => throw JThrown(value.read());
    }
    if (peek == 'let' || peek == 'const') {
      if (!allowLexical) _unsupported();
      final declarationScope = scope;
      final constant = tokens[at++] == 'const';
      final declarations = <_EvalRead>[];
      do {
        final name = peek;
        if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name) ||
            const {
              'let',
              'const',
              'var',
              'return',
              'this',
              'true',
              'false',
              'null',
              'function',
              'class',
              'new',
              'if',
              'else',
              'for',
              'while',
              'throw',
              'import',
              'export',
              'super',
              'delete',
              'void',
              'typeof',
            }.contains(name) ||
            !lexicalNames.add(name))
          _unsupported();
        at++;
        final initialized = take('=');
        if (constant && !initialized) _unsupported();
        final initializer = initialized
            ? expression()
            : _EvalExpr(() => jUndefined);
        declarations.add(
          () => declarationScope.current.define(
            name,
            initializer.read(),
            constant: constant,
          ),
        );
      } while (take(','));
      return () {
        for (final declaration in declarations) declaration();
        return _jRuntimeEmpty;
      };
    }
    return expression().read;
  }

  void instantiate() {
    for (final name in lexicalNames) scope.current.reserve(name);
  }

  _EvalExpr expression([int min = 0]) {
    var left = primary();
    while (true) {
      final op = peek;
      final power = precedence[op];
      if (power == null || power < min) break;
      at++;
      final right = expression(power + (op == '**' ? 0 : 1));
      final previous = left;
      left = _EvalExpr(() {
        final value = previous.read();
        if (op == '&&') return jTruthy(value) ? right.read() : value;
        if (op == '||') return jTruthy(value) ? value : right.read();
        if (op == '??') return jNullish(value) ? right.read() : value;
        return jBinary(op, value, right.read());
      });
    }
    if (min == 0 && take('?')) {
      final condition = left;
      final yes = expression();
      expect(':');
      final no = expression();
      left = _EvalExpr(
        () => jTruthy(condition.read()) ? yes.read() : no.read(),
      );
    }
    if (min == 0 && assignments.contains(peek)) {
      final operator = tokens[at++];
      final target = left;
      if (target.write == null && target.reference == null) _unsupported();
      final right = expression();
      left = _EvalExpr(() {
        final ref =
            target.reference?.call() ?? JRef(target.read, target.write!);
        return jAssign(ref, operator, right.read);
      });
    }
    return left;
  }

  JRef Function() updateReference(_EvalExpr operand) {
    final member = operand.reference;
    if (member != null) return member;
    final write = operand.write;
    if (write == null) _unsupported();
    return () => JRef(operand.read, write);
  }

  _EvalExpr primary() {
    if (peek == '++' || peek == '--') {
      final delta = tokens[at++] == '++' ? 1 : -1;
      final reference = updateReference(primary());
      return _EvalExpr(() => jUpdate(reference(), delta, true));
    }
    var value = atom();
    while (true) {
      final previous = value;
      if (peek == '.' || peek == '[') {
        late _EvalExpr key;
        if (take('[')) {
          key = expression();
          expect(']');
        } else {
          expect('.');
          final name = peek;
          if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name))
            _unsupported();
          at++;
          key = _EvalExpr(() => name);
        }
        JRef reference() {
          final object = previous.read();
          final property = jPropertyKey(key.read());
          return JRef.member(object, property);
        }

        value = _EvalExpr(() => reference().read(), null, reference, () {
          final object = previous.read();
          final property = jPropertyKey(key.read());
          return JCallSite.member(object, property);
        });
      } else if (take('(')) {
        final args = <_EvalExpr>[];
        if (!take(')')) {
          do {
            args.add(expression());
          } while (take(',') && peek != ')');
          expect(')');
        }
        value = _EvalExpr(() {
          final call = previous.callSite?.call() ?? JCallSite(previous.read());
          return call.call([for (final arg in args) arg.read()]);
        });
      } else {
        if (!lineBreaks.contains(at) && (peek == '++' || peek == '--')) {
          final delta = tokens[at++] == '++' ? 1 : -1;
          final reference = updateReference(value);
          return _EvalExpr(() => jUpdate(reference(), delta, false));
        }
        return value;
      }
    }
  }

  _EvalExpr atom() {
    final token = peek;
    if (token.isEmpty) _unsupported();
    if (take('(')) {
      final value = expression();
      expect(')');
      return value;
    }
    if (token == '+' ||
        token == '-' ||
        token == '!' ||
        token == '~' ||
        token == 'void' ||
        token == 'typeof') {
      at++;
      if (token == 'typeof' &&
          !const {
            'true',
            'false',
            'null',
            'this',
            'void',
            'typeof',
          }.contains(peek) &&
          RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(peek) &&
          !const {'.', '[', '('}.contains(tokens[at + 1])) {
        final name = tokens[at++];
        final lexicalScope = scope;
        return _EvalExpr(
          () => jUnary('typeof', lexicalScope.current.getForTypeof(name)),
        );
      }
      final argument = primary();
      return _EvalExpr(() => jUnary(token, argument.read()));
    }
    at++;
    if (RegExp(r'^\d').hasMatch(token)) {
      final value = double.tryParse(token);
      if (value == null) _unsupported();
      return _EvalExpr(() => value);
    }
    if (token.startsWith('"') || token.startsWith("'")) {
      final result = StringBuffer();
      for (var i = 1; i < token.length - 1; i++) {
        var char = token[i];
        if (char == r'\') {
          if (++i >= token.length - 1) _unsupported();
          char = token[i];
          const escapes = {
            'n': '\n',
            'r': '\r',
            't': '\t',
            'b': '\b',
            'f': '\f',
            'v': '\x0b',
            '0': '\x00',
            '\\': '\\',
            "'": "'",
            '"': '"',
          };
          if (!escapes.containsKey(char)) _unsupported();
          char = escapes[char]!;
        }
        result.write(char);
      }
      final value = result.toString();
      return _EvalExpr(() => value);
    }
    if (token == 'true') return _EvalExpr(() => true);
    if (token == 'false') return _EvalExpr(() => false);
    if (token == 'null') return _EvalExpr(() => null);
    if (token == 'this') return _EvalExpr(() => thisValue);
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(token)) _unsupported();
    const reserved = {
      'let',
      'const',
      'var',
      'function',
      'class',
      'return',
      'throw',
      'if',
      'while',
      'for',
      'new',
      'delete',
      'await',
      'yield',
      'in',
      'instanceof',
    };
    if (reserved.contains(token)) _unsupported();
    final lexicalScope = scope;
    return _EvalExpr(
      () => lexicalScope.current.get(token),
      (value) => lexicalScope.current.put(token, value),
    );
  }
}

dynamic jRuntimeEval(dynamic value, JScope scope, dynamic thisValue) {
  if (value is! String) return value;
  final parser = _RuntimeEvalParser(value, JScope(scope), thisValue);
  final statements = parser.parse();
  parser.instantiate();
  return _runRuntimeStatements(statements);
}

dynamic _runRuntimeStatements(
  List<_EvalRead> statements, {
  dynamic initial = jUndefined,
}) {
  dynamic result = initial;
  for (final statement in statements) {
    try {
      final value = statement();
      if (!identical(value, _jRuntimeEmpty)) result = value;
    } on _RuntimeJump catch (jump) {
      jump.updateEmpty(result);
      rethrow;
    }
  }
  return result;
}

dynamic jDirectRuntimeEval(
  dynamic callee,
  List<dynamic> args,
  JScope scope,
  dynamic thisValue,
) => callee is JEvalFunction
    ? jRuntimeEval(jArg(args, 0), scope, thisValue)
    : jCall(callee, args);

class _RuntimeJump implements Exception {
  final bool isBreak;
  dynamic value = _jRuntimeEmpty;
  _RuntimeJump(this.isBreak);

  void updateEmpty(dynamic previous) {
    if (identical(value, _jRuntimeEmpty)) value = previous;
  }
}

bool _runtimeBindingName(String name) => !const {
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'function',
  'if',
  'import',
  'in',
  'instanceof',
  'let',
  'new',
  'null',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
}.contains(name);

class _RuntimeReturn implements Exception {
  final dynamic value;
  _RuntimeReturn(this.value);
}

JFunction jRuntimeFunction(JScope root, List<dynamic> args, String kind) {
  if (kind != 'normal') {
    throw JThrown(JError('TypeError', 'Unsupported dynamic function kind'));
  }
  final strings = [for (final arg in args) jString(arg)];
  final parameters = strings.length < 2
      ? ''
      : strings.take(strings.length - 1).join(',');
  final body = strings.isEmpty ? '' : strings.last;
  final names = parameters.trim().isEmpty
      ? <String>[]
      : parameters.split(',').map((s) => s.trim()).toList();
  const reserved = {
    'this',
    'null',
    'true',
    'false',
    'return',
    'class',
    'function',
    'new',
    'let',
    'const',
    'var',
    'if',
    'for',
    'while',
    'throw',
    'super',
    'import',
    'export',
  };
  for (final name in names) {
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name) ||
        reserved.contains(name)) {
      throw JThrown(JError('SyntaxError', 'Unsupported Function parameters'));
    }
  }
  final validation = _RuntimeEvalParser(
    body,
    JScope(root.scriptGlobalScope),
    jUndefined,
    functionBody: true,
  );
  validation.parse();
  final strict = validation.strictFunction;
  if (names.any(validation.lexicalNames.contains) ||
      (strict &&
          (names.toSet().length != names.length ||
              names.contains('eval') ||
              names.contains('arguments')))) {
    throw JThrown(JError('SyntaxError', 'Invalid Function parameter binding'));
  }
  final function = jFunction((actual, receiver, newTarget) {
    final parametersScope = JScope(root.scriptGlobalScope);
    for (final name in names.toSet()) {
      parametersScope.define(name, jArg(actual, names.lastIndexOf(name)));
    }
    if (!names.contains('arguments')) {
      parametersScope.define('arguments', jArgumentsObject(actual));
    }
    final parser = _RuntimeEvalParser(
      body,
      JScope(parametersScope),
      !strict && jNullish(receiver) ? root.globalThisValue : receiver,
      functionBody: true,
    );
    final statements = parser.parse();
    parser.instantiate();
    try {
      for (final statement in statements) statement();
    } on _RuntimeReturn catch (completion) {
      return completion.value;
    }
    return jUndefined;
  });
  return jNamedFunction(
    function,
    'anonymous',
    names.length,
    source: 'function anonymous($parameters\n) {\n$body\n}',
  );
}
