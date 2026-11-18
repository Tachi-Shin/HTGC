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
const _noNewTarget = _NoNewTarget();

class _NoNewTarget {
  const _NoNewTarget();
}

typedef _EvalRead = dynamic Function();

class _EvalExpr {
  final _EvalRead read;
  final dynamic Function(dynamic)? write;
  final JRef Function()? reference;
  final JCallSite Function()? callSite;
  final String? identifier;
  final bool anonymous;
  final bool Function()? remove;
  bool get directEval => identifier == "eval";
  _EvalExpr(
    this.read, [
    this.write,
    this.reference,
    this.callSite,
    this.identifier,
    this.anonymous = false,
    this.remove,
  ]);
  dynamic readNamed(dynamic key) {
    final value = read();
    if (anonymous && key != null) {
      (value as JFunction).properties['name'] = jFunctionKeyName(key);
    }
    return value;
  }
}

typedef _BindValue = void Function(String name, dynamic value);

class _RuntimeBinding {
  final List<String> names;
  final void Function(_EvalRead, _BindValue) bindFrom;
  final bool simple;
  final bool hasDefault;
  _RuntimeBinding(
    this.names,
    this.bindFrom, {
    this.simple = false,
    this.hasDefault = false,
  });

  void bind(dynamic value, _BindValue write) => bindFrom(() => value, write);

  void assign(dynamic value) => bind(value, (_, _) {
    throw StateError('Unexpected identifier binding in assignment pattern');
  });
}

class _RuntimeLexicalScope {
  JScope current;
  _RuntimeLexicalScope(this.current);
}

class _RuntimeEvalParser {
  final String source;
  _RuntimeLexicalScope scope;
  int loopDepth = 0, switchDepth = 0;
  final activeLabels = <String, bool>{};
  final dynamic thisValue;
  final bool functionBody;
  final List<String> tokens = [];
  final offsets = <int>[];
  final regexLiterals = <int, (String pattern, String flags)>{};
  final hoisted = [<void Function()>[]];
  bool strictDirective = false;
  final dynamic newTarget;
  final JObject? home;
  final lineBreaks = <int>{};
  bool strictFunction;
  int at = 0;
  final lexicalEnvironments = [<String>{}];
  final varNamesByEnvironment = [<String>{}];
  Set<String> get lexicalNames => lexicalEnvironments.last;
  final variableNames = <String>{};
  final functionNames = <String>{};
  final JScope variableScope;

  void enterEnvironment() {
    hoisted.add([]);
    lexicalEnvironments.add(<String>{});
    varNamesByEnvironment.add(<String>{});
  }

  void leaveEnvironment() {
    hoisted.removeLast();
    lexicalEnvironments.removeLast();
    varNamesByEnvironment.removeLast();
  }

  _RuntimeEvalParser(
    this.source,
    JScope scope,
    this.thisValue, {
    this.functionBody = false,
    this.newTarget = _noNewTarget,
    this.home,
    JScope? variables,
    this.strictFunction = false,
  }) : variableScope = variables ?? scope,
       scope = _RuntimeLexicalScope(scope) {
    final token = RegExp(
      r'''\s+|//[^\r\n\u2028\u2029]*|/\*[\s\S]*?\*/|(?:[A-Za-z_$][A-Za-z0-9_$]*)|(?:\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)|(?:"(?:\\.|[^"\\\n\r])*"|'(?:\\.|[^'\\\n\r])*')|(?:\.\.\.|\?\.(?!\d)|>>>=|<<=|>>=|\*\*=|&&=|\|\|=|\?\?=|%=|&=|\|=|\^=|===|!==|>>>|\*\*|==|!=|<=|>=|&&|\|\||\?\?|<<|>>|\+\+|--|\+=|-=|\*=|/=|=>)|[{}()\[\].,:?&|^+\-*/%<>=!~;]''',
    );
    var pos = 0;
    final parens = <bool>[];
    final controlHeads = const {
      'if',
      'while',
      'for',
      'with',
      'switch',
      'catch',
    };
    bool afterControlHead = false;
    while (pos < source.length) {
      final previous = tokens.isEmpty ? '' : tokens.last;
      final member =
          tokens.length > 1 && ['.', '?.'].contains(tokens[tokens.length - 2]);
      if (source[pos] == '/' &&
          pos + 1 < source.length &&
          !const {'/', '*'}.contains(source[pos + 1]) &&
          (afterControlHead || (!member && _regexPrefix.contains(previous)))) {
        final literal = _readRegexLiteral(pos);
        if (literal != null) {
          final (pattern, flags, end) = literal;
          regexLiterals[tokens.length] = (pattern, flags);
          offsets.add(pos);
          tokens.add(source.substring(pos, end));
          pos = end;
          afterControlHead = false;
          continue;
        }
      }
      final match = token.matchAsPrefix(source, pos);
      // Preserve invalid code units as tokens so the parser itself rejects
      // them, including a slash expression with an unterminated pattern.
      final word = match?.group(0) ?? source[pos];
      if (word.trim().isNotEmpty &&
          !word.startsWith('//') &&
          !word.startsWith('/*')) {
        offsets.add(pos);
        tokens.add(word);
        afterControlHead = false;
        if (word == '(') {
          parens.add(!member && controlHeads.contains(previous));
        } else if (word == ')' && parens.isNotEmpty) {
          afterControlHead = parens.removeLast();
        }
      } else if (RegExp(r'[\n\r\u2028\u2029]').hasMatch(word)) {
        lineBreaks.add(tokens.length);
      }
      pos = match?.end ?? pos + 1;
    }
    offsets.add(source.length);
    tokens.add('');
  }

  static const _regexPrefix = {
    '',
    ';',
    ':',
    '(',
    '[',
    '{',
    ',',
    '?',
    '=',
    '=>',
    'return',
    'throw',
    'case',
    'else',
    'do',
    'void',
    'typeof',
    'delete',
    'in',
    'instanceof',
    '!',
    '~',
    '+',
    '-',
    '*',
    '/',
    '%',
    '**',
    '<',
    '>',
    '<=',
    '>=',
    '==',
    '!=',
    '===',
    '!==',
    '&',
    '|',
    '^',
    '&&',
    '||',
    '??',
    '<<',
    '>>',
    '>>>',
    '+=',
    '-=',
    '*=',
    '/=',
    '%=',
    '**=',
    '&&=',
    '||=',
    '??=',
    '&=',
    '|=',
    '^=',
    '<<=',
    '>>=',
    '>>>=',
  };
  static final _regexFlags = RegExp(
    r'[$_\p{ID_Continue}\\\u200c\u200d]*',
    unicode: true,
  );

  (String, String, int)? _readRegexLiteral(int start) {
    var characterClass = false;
    for (var pos = start + 1; pos < source.length; pos++) {
      final c = source[pos];
      if ('\r\n\u2028\u2029'.contains(c)) return null;
      if (c == r'\') {
        pos++;
        if (pos == source.length || '\r\n\u2028\u2029'.contains(source[pos]))
          return null;
      } else if (c == '/' && !characterClass) {
        final flags = _regexFlags.matchAsPrefix(source, pos + 1)!;
        return (source.substring(start + 1, pos), flags.group(0)!, flags.end);
      } else if (c == '[') {
        characterClass = true;
      } else if (c == ']') {
        characterClass = false;
      }
    }
    return null;
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
    'in': 7,
    'instanceof': 7,
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
    var directives = !inBlock;
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
          strictDirective = true;
          strictFunction = true;
        }
      }
    }
    return statements;
  }

  _EvalRead statement({
    bool allowLexical = true,
    Set<String> labels = const {},
  }) {
    if (peek.isNotEmpty && tokens[at + 1] == ':') {
      final nested = <String>{};
      while (peek.isNotEmpty && tokens[at + 1] == ':') {
        final name = bindingIdentifier();
        if (!nested.add(name) || activeLabels.containsKey(name)) _unsupported();
        expect(':');
      }
      final iteration = const {'for', 'while', 'do'}.contains(peek);
      for (final name in nested) activeLabels[name] = iteration;
      late final _EvalRead body;
      try {
        body = statement(allowLexical: false, labels: nested);
      } finally {
        for (final name in nested) activeLabels.remove(name);
      }
      return () {
        try {
          return body();
        } on _RuntimeJump catch (jump) {
          if (jump.isBreak && nested.contains(jump.label)) return jump.value;
          rethrow;
        }
      };
    }
    if (take('with')) {
      if (strictFunction) _unsupported();
      expect('(');
      final object = sequence();
      expect(')');
      final parent = scope;
      final nested = _RuntimeLexicalScope(parent.current);
      scope = nested;
      try {
        final body = statement(allowLexical: false);
        return () {
          nested.current = JWithScope(parent.current, object.read());
          try {
            final value = body();
            return identical(value, _jRuntimeEmpty) ? jUndefined : value;
          } on _RuntimeJump catch (jump) {
            jump.updateEmpty(jUndefined);
            rethrow;
          }
        };
      } finally {
        scope = parent;
      }
    }
    if (take('switch')) return switchStatement();
    if (take(';')) return () => _jRuntimeEmpty;
    if (peek == '{') return block();
    if (peek == 'function') {
      if (!allowLexical) _unsupported();
      return functionDeclaration();
    }
    if (take('for')) return forStatement(labels);
    if (take('while')) {
      expect('(');
      final condition = sequence();
      expect(')');
      final body = loopBody();
      return () => runLoop(condition, body, labels: labels);
    }
    if (take('do')) {
      final body = loopBody();
      expect('while');
      expect('(');
      final condition = sequence();
      expect(')');
      take(';');
      return () => runLoop(condition, body, first: true, labels: labels);
    }
    if (take('try')) {
      final body = block();
      if (take('catch')) {
        if (take('(')) {
          final parent = scope;
          final binding = _RuntimeLexicalScope(parent.current);
          scope = binding;
          enterEnvironment();
          late final _RuntimeBinding pattern;
          late final _EvalRead catchBody;
          try {
            pattern = bindingPattern();
            expect(')');
            if (pattern.names.toSet().length != pattern.names.length)
              _unsupported();
            if (!pattern.simple) lexicalNames.addAll(pattern.names);
            catchBody = block(forbiddenNames: pattern.names);
          } finally {
            scope = parent;
            leaveEnvironment();
          }
          return finishTry(body, (error) {
            final local = JScope(parent.current);
            if (pattern.simple) local.simpleCatchName = pattern.names.single;
            binding.current = local;
            for (final name in pattern.names) local.reserve(name);
            initializeBinding(
              pattern,
              error,
              local,
              constant: false,
              variable: false,
            );
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
      final condition = sequence();
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

  _EvalRead block({List<String> forbiddenNames = const []}) {
    expect('{');
    final parent = scope;
    final blockScope = _RuntimeLexicalScope(parent.current);
    scope = blockScope;
    enterEnvironment();
    final blockNames = lexicalNames;
    final functions = hoisted.last;
    try {
      final statements = parse(inBlock: true);
      expect('}');
      if (forbiddenNames.any(blockNames.contains)) _unsupported();
      return () {
        final local = JScope(parent.current);
        blockScope.current = local;
        for (final name in blockNames) local.reserve(name);
        for (final initialize in functions) initialize();
        return _runRuntimeStatements(statements, initial: _jRuntimeEmpty);
      };
    } finally {
      scope = parent;
      leaveEnvironment();
    }
  }

  _EvalRead switchStatement() {
    expect('(');
    final discriminant = sequence();
    expect(')');
    expect('{');
    final parent = scope;
    final local = _RuntimeLexicalScope(parent.current);
    scope = local;
    enterEnvironment();
    switchDepth++;
    final names = lexicalNames;
    final functions = hoisted.last;
    final clauses = <(_EvalExpr?, List<_EvalRead>)>[];
    var fallback = -1;
    try {
      while (!take('}')) {
        _EvalExpr? test;
        if (take('case')) {
          test = sequence();
        } else {
          expect('default');
          if (fallback >= 0) _unsupported();
          fallback = clauses.length;
        }
        expect(':');
        final body = <_EvalRead>[];
        while (!const {'case', 'default', '}'}.contains(peek))
          body.add(statement());
        clauses.add((test, body));
      }
    } finally {
      switchDepth--;
      leaveEnvironment();
      scope = parent;
    }
    return () {
      final key = discriminant.read();
      local.current = JScope(parent.current);
      for (final name in names) local.current.reserve(name);
      for (final initialize in functions) initialize();
      var start = clauses.indexWhere(
        (entry) =>
            entry.$1 != null && jBinary('===', key, entry.$1!.read()) == true,
      );
      if (start < 0) start = fallback;
      dynamic value = jUndefined;
      if (start < 0) return value;
      try {
        for (var index = start; index < clauses.length; index++) {
          value = _runRuntimeStatements(clauses[index].$2, initial: value);
        }
      } on _RuntimeJump catch (jump) {
        if (!jump.isBreak || jump.label != null) rethrow;
        return jump.value;
      }
      return value;
    };
  }

  _EvalRead forStatement(Set<String> labels) {
    expect('(');
    final parent = scope;
    final loopScope = _RuntimeLexicalScope(parent.current);
    scope = loopScope;
    enterEnvironment();
    final names = lexicalNames;
    try {
      final lexical = peek == 'let' || peek == 'const';
      final constant = peek == 'const';
      final variable = peek == 'var';
      _EvalRead? start;
      _EvalExpr? target;
      _RuntimeBinding? binding;
      _RuntimeBinding? assignment;
      if (lexical || variable) {
        final kind = tokens[at++];
        final pattern = bindingPattern();
        if (peek == 'in' || peek == 'of') {
          registerBinding(pattern, variable: variable);
          binding = pattern;
        } else {
          start = declaration(kind: kind, first: pattern);
        }
      } else if (peek != ';') {
        assignment = assignmentPattern(const {'in', 'of'});
        if (assignment == null) {
          target = sequence(noIn: true);
          start = target.read;
        }
      }
      if (peek == 'in' || peek == 'of') {
        final of = tokens[at++] == 'of';
        final assign = binding == null && assignment == null
            ? (target == null ? _unsupported() : assignmentReference(target))
            : null;
        final source = of ? expression() : sequence();
        expect(')');
        final body = loopBody();
        return () {
          loopScope.current = JScope(parent.current);
          if (binding != null && !variable) {
            for (final name in binding.names) loopScope.current.reserve(name);
          }
          final input = source.read();
          dynamic iteration(dynamic item) {
            if (binding != null) {
              if (!variable) {
                loopScope.current = JScope(parent.current);
                for (final name in binding.names)
                  loopScope.current.reserve(name);
              }
              initializeBinding(
                binding,
                item,
                loopScope.current,
                constant: constant,
                variable: variable,
              );
            } else if (assignment != null) {
              assignment.assign(item);
            } else {
              assign!().write(item);
            }
            return body();
          }

          return of
              ? runForOf(input, iteration, labels)
              : runForIn(input, iteration, labels);
        };
      }
      expect(';');
      final condition = peek == ';' ? _EvalExpr(() => true) : sequence();
      expect(';');
      final update = peek == ')' ? null : sequence();
      expect(')');
      final body = loopBody();
      final iterationNames = !constant ? names.toList() : <String>[];
      void nextEnvironment() {
        if (iterationNames.isNotEmpty) {
          loopScope.current = loopScope.current.copyIteration(iterationNames);
        }
      }

      return () {
        loopScope.current = JScope(parent.current);
        for (final name in names) loopScope.current.reserve(name);
        start?.call();
        nextEnvironment();
        return runLoop(
          condition,
          body,
          labels: labels,
          update: () {
            nextEnvironment();
            update?.read();
          },
        );
      };
    } finally {
      scope = parent;
      leaveEnvironment();
    }
  }

  dynamic runForOf(
    dynamic source,
    dynamic Function(dynamic) body,
    Set<String> labels,
  ) {
    final iterator = jGetIterator(source);
    try {
      return runLoop(
        _EvalExpr(iterator.advance),
        () => body(iterator.current),
        labels: labels,
      );
    } on JThrown {
      iterator.close(suppressErrors: true);
      rethrow;
    } finally {
      iterator.close();
    }
  }

  dynamic runForIn(
    dynamic source,
    dynamic Function(dynamic) body,
    Set<String> labels,
  ) {
    final keys = jForInKeys(source).iterator;
    return runLoop(
      _EvalExpr(keys.moveNext),
      () => body(keys.current),
      labels: labels,
    );
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
    Set<String> labels = const {},
    void Function()? update,
  }) {
    dynamic result = jUndefined;
    while (first || jTruthy(condition.read())) {
      first = false;
      try {
        final value = body();
        if (!identical(value, _jRuntimeEmpty)) result = value;
      } on _RuntimeJump catch (jump) {
        jump.updateEmpty(result);
        if (jump.label != null && !labels.contains(jump.label)) rethrow;
        result = jump.value;
        if (jump.isBreak) break;
      }
      update?.call();
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
      final isBreak = tokens[at++] == 'break';
      String? label;
      if (!lineBreaks.contains(at) &&
          RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(peek)) {
        label = bindingIdentifier();
        if (!activeLabels.containsKey(label) ||
            !isBreak && !activeLabels[label]!)
          _unsupported();
      } else if (loopDepth == 0 && (!isBreak || switchDepth == 0)) {
        _unsupported();
      }
      return () => throw _RuntimeJump(isBreak, label);
    }
    if (take('return')) {
      if (!functionBody) _unsupported();
      final value =
          peek.isEmpty || peek == ';' || peek == '}' || lineBreaks.contains(at)
          ? _EvalExpr(() => jUndefined)
          : sequence();
      return () => throw _RuntimeReturn(value.read());
    }
    if (take('throw')) {
      if (lineBreaks.contains(at)) _unsupported();
      final value = sequence();
      return () => throw JThrown(value.read());
    }
    if (peek == 'let' || peek == 'const') {
      if (!allowLexical) _unsupported();
      return declaration();
    }
    if (peek == 'var') return declaration();
    if (take('debugger')) return () => _jRuntimeEmpty;
    return sequence().read;
  }

  String bindingIdentifier() {
    final name = peek;
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name) ||
        !_runtimeBindingName(name) ||
        (strictFunction &&
            const {
              'eval',
              'arguments',
              'yield',
              'implements',
              'interface',
              'package',
              'private',
              'protected',
              'public',
              'static',
            }.contains(name)))
      _unsupported();
    at++;
    return name;
  }

  _RuntimeBinding identifierPattern() {
    final name = bindingIdentifier();
    return _RuntimeBinding(
      [name],
      (read, bind) => bind(name, read()),
      simple: true,
    );
  }

  _RuntimeBinding bindingElement({
    _RuntimeBinding? pattern,
    bool assignment = false,
  }) {
    final target = pattern ?? bindingPattern(assignment: assignment);
    if (!take('=')) return target;
    final fallback = expression();
    return _RuntimeBinding(target.names, (read, bind) {
      target.bindFrom(() {
        final value = read();
        return identical(value, jUndefined)
            ? fallback.readNamed(target.simple ? target.names.single : null)
            : value;
      }, bind);
    }, hasDefault: true);
  }

  _RuntimeBinding? assignmentPattern(Set<String> terminators) {
    if (peek != '[' && peek != '{') return null;
    final start = at;
    try {
      final pattern = bindingPattern(assignment: true);
      if (terminators.contains(peek)) return pattern;
    } on JThrown {
      // The same prefix can be an ordinary array or object expression.
    }
    at = start;
    return null;
  }

  _RuntimeBinding assignmentLeaf(JRef Function() reference) =>
      _RuntimeBinding(const [], (read, _) {
        final target = reference();
        target.write(read());
      });

  _RuntimeBinding bindingPattern({bool assignment = false}) {
    if (take('[')) return arrayBinding(assignment);
    if (take('{')) return objectBinding(assignment);
    return assignment
        ? assignmentLeaf(assignmentReference(primary()))
        : identifierPattern();
  }

  _RuntimeBinding arrayBinding(bool assignment) {
    final entries = <_RuntimeBinding?>[];
    _RuntimeBinding? rest;
    while (!take(']')) {
      if (take(',')) {
        entries.add(null);
        continue;
      }
      if (take('...')) {
        rest = bindingPattern(assignment: assignment);
        expect(']');
        break;
      }
      entries.add(bindingElement(assignment: assignment));
      if (!take(',')) {
        expect(']');
        break;
      }
    }
    return _RuntimeBinding(
      [for (final entry in entries) ...?entry?.names, ...?rest?.names],
      (read, bind) {
        final iterator = jGetIterator(read());
        dynamic readElement() =>
            iterator.advance() ? iterator.current : jUndefined;
        try {
          for (final entry in entries) {
            if (entry == null) {
              iterator.advance();
            } else {
              entry.bindFrom(readElement, bind);
            }
          }
          rest?.bindFrom(() {
            final remaining = <dynamic>[];
            while (iterator.advance()) remaining.add(iterator.current);
            return remaining;
          }, bind);
        } on JThrown {
          iterator.close(suppressErrors: true);
          rethrow;
        } finally {
          iterator.close();
        }
      },
    );
  }

  _RuntimeBinding objectBinding(bool assignment) {
    final entries = <(_EvalRead, _RuntimeBinding)>[];
    _RuntimeBinding? rest;
    while (!take('}')) {
      if (take('...')) {
        rest = assignment
            ? assignmentLeaf(assignmentReference(primary()))
            : identifierPattern();
        expect('}');
        break;
      }
      if (take('[')) {
        final key = expression();
        expect(']');
        expect(':');
        entries.add((key.read, bindingElement(assignment: assignment)));
      } else {
        final token = peek;
        if (RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(token)) {
          if (tokens[at + 1] == ':') {
            at += 2;
            entries.add((() => token, bindingElement(assignment: assignment)));
          } else {
            late final _RuntimeBinding target;
            if (assignment) {
              if (!_runtimeBindingName(token)) _unsupported();
              at++;
              final binding = scope;
              target = assignmentLeaf(
                () =>
                    JRef.scope(binding.current, token, strict: strictFunction),
              );
            } else {
              target = identifierPattern();
            }
            entries.add((() => token, bindingElement(pattern: target)));
          }
        } else {
          if (!token.startsWith('"') &&
              !token.startsWith("'") &&
              !RegExp(r'^\d').hasMatch(token))
            _unsupported();
          final key = atom();
          expect(':');
          entries.add((key.read, bindingElement(assignment: assignment)));
        }
      }
      if (!take(',')) {
        expect('}');
        break;
      }
    }
    return _RuntimeBinding(
      [for (final (_, pattern) in entries) ...pattern.names, ...?rest?.names],
      (read, bind) {
        final object = jRequireCoercible(read());
        final keys = <Object>[];
        for (final (readKey, pattern) in entries) {
          final key = jPropertyKey(readKey());
          keys.add(key);
          pattern.bindFrom(() => jGet(object, key), bind);
        }
        rest?.bindFrom(() => jCopyProperties(object, excluding: keys), bind);
      },
    );
  }

  void registerBinding(_RuntimeBinding pattern, {required bool variable}) {
    for (final name in pattern.names) {
      if (!variable) {
        if (!lexicalNames.add(name) ||
            varNamesByEnvironment.last.contains(name))
          _unsupported();
        continue;
      }
      if (lexicalEnvironments.any((names) => names.contains(name))) {
        _unsupported();
      }
      variableNames.add(name);
      for (final names in varNamesByEnvironment) names.add(name);
    }
  }

  void initializeBinding(
    _RuntimeBinding pattern,
    dynamic value,
    JScope environment, {
    required bool constant,
    required bool variable,
  }) {
    pattern.bind(value, (name, boundValue) {
      if (variable) {
        environment.put(name, boundValue);
      } else {
        environment.define(name, boundValue, constant: constant);
      }
    });
  }

  _EvalRead declaration({String? kind, _RuntimeBinding? first}) {
    final declarationScope = scope;
    final keyword = kind ?? tokens[at++];
    final constant = keyword == 'const';
    final variable = keyword == 'var';
    final declarations = <_EvalRead>[];
    var pattern = first ?? bindingPattern();
    while (true) {
      final target = pattern;
      registerBinding(target, variable: variable);
      if (take('=')) {
        final initializer = expression();
        declarations.add(
          () => initializeBinding(
            target,
            initializer.readNamed(target.simple ? target.names.single : null),
            declarationScope.current,
            constant: constant,
            variable: variable,
          ),
        );
      } else if (constant || !target.simple) {
        _unsupported();
      } else if (!variable) {
        declarations.add(
          () => initializeBinding(
            target,
            jUndefined,
            declarationScope.current,
            constant: false,
            variable: false,
          ),
        );
      }
      if (!take(',')) break;
      pattern = bindingPattern();
    }
    return () {
      for (final declaration in declarations) declaration();
      return _jRuntimeEmpty;
    };
  }

  List<(_RuntimeBinding, bool)> parameters() {
    final result = <(_RuntimeBinding, bool)>[];
    while (peek.isNotEmpty) {
      final rest = take('...');
      result.add((rest ? bindingPattern() : bindingElement(), rest));
      if (rest || !take(',')) break;
    }
    if (peek.isNotEmpty) _unsupported();
    return result;
  }

  void instantiate() {
    for (final name in variableNames) variableScope.declareVar(name);
    for (final name in lexicalNames) scope.current.reserve(name);
    for (final initialize in hoisted.single) initialize();
  }

  _EvalExpr sequence({bool noIn = false}) {
    final initial = expression(0, noIn);
    if (!take(',')) return initial;
    final entries = [initial];
    do {
      entries.add(expression(0, noIn));
    } while (take(','));
    return _EvalExpr(() {
      dynamic result;
      for (final item in entries) result = item.read();
      return result;
    });
  }

  _EvalExpr expression([int min = 0, bool noIn = false]) {
    if (min == 0) {
      if (startsArrow()) return arrowFunction();
      final pattern = assignmentPattern(const {'='});
      if (pattern != null) {
        expect('=');
        final right = expression(0, noIn);
        return _EvalExpr(() {
          final value = right.read();
          pattern.assign(value);
          return value;
        });
      }
    }
    var left = primary();
    while (true) {
      final op = peek;
      final power = precedence[op];
      if (power == null || power < min || (noIn && op == 'in')) break;
      at++;
      final right = expression(power + (op == '**' ? 0 : 1), noIn);
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
      final no = expression(0, noIn);
      left = _EvalExpr(
        () => jTruthy(condition.read()) ? yes.read() : no.read(),
      );
    }
    if (min == 0 && assignments.contains(peek)) {
      final operator = tokens[at++];
      final target = left;
      final getReference = assignmentReference(target);
      final right = expression(0, noIn);
      left = _EvalExpr(() {
        final ref = getReference();
        return jAssign(
          ref,
          operator,
          () => right.readNamed(
            const {'=', '&&=', '||=', '??='}.contains(operator)
                ? target.identifier
                : null,
          ),
        );
      });
    }
    return left;
  }

  JRef Function() assignmentReference(_EvalExpr operand) {
    if (strictFunction &&
        const {'eval', 'arguments'}.contains(operand.identifier))
      _unsupported();
    final member = operand.reference;
    if (member != null) return member;
    final write = operand.write;
    if (write == null) _unsupported();
    return () => JRef(operand.read, write);
  }

  _EvalExpr primary() {
    if (take('delete')) {
      final operand = primary();
      if (operand.identifier != null && strictFunction) _unsupported();
      return _EvalExpr(() {
        if (operand.remove != null) return operand.remove!();
        operand.read();
        return true;
      });
    }
    if (peek == '++' || peek == '--') {
      final delta = tokens[at++] == '++' ? 1 : -1;
      final reference = assignmentReference(primary());
      return _EvalExpr(() => jUpdate(reference(), delta, true));
    }
    final value = suffixes(newOrAtom());
    if (!lineBreaks.contains(at) && (peek == '++' || peek == '--')) {
      final delta = tokens[at++] == '++' ? 1 : -1;
      final reference = assignmentReference(value);
      return _EvalExpr(() => jUpdate(reference(), delta, false));
    }
    return value;
  }

  _EvalExpr newOrAtom() {
    if (!take('new')) return atom();
    if (take('.')) {
      expect('target');
      if (identical(newTarget, _noNewTarget)) _unsupported();
      return _EvalExpr(() => newTarget);
    }
    if (const {'+', '-', '!', '~', 'void', 'typeof', 'delete'}.contains(peek))
      _unsupported();
    final constructor = suffixes(newOrAtom(), memberOnly: true);
    final args = take('(') ? expressionList(')') : <(_EvalExpr?, bool)>[];
    return _EvalExpr(() => jNew(constructor.read(), evaluateList(args)));
  }

  _EvalExpr suffixes(_EvalExpr value, {bool memberOnly = false}) {
    var chain = false;
    while (true) {
      final previous = value;
      final optional = take('?.');
      if (optional && memberOnly) _unsupported();
      chain |= optional;
      if (peek == '(' && !memberOnly) {
        at++;
        final args = expressionList(')');
        final lexicalScope = scope;
        value = _EvalExpr(() {
          final call = previous.callSite?.call() ?? JCallSite(previous.read());
          if (call.skipped || optional && jNullish(call.function))
            return jShortCircuit;
          final arguments = evaluateList(args);
          if (previous.directEval && !optional) {
            return jDirectRuntimeEval(
              call.function,
              arguments,
              lexicalScope.current,
              thisValue,
              strict: strictFunction,
              newTarget: newTarget,
              home: home,
              receiver: call.receiver,
            );
          }
          return call.call(arguments);
        });
      } else if (optional || peek == '.' || peek == '[') {
        late _EvalExpr key;
        if (take('[')) {
          key = sequence();
          expect(']');
        } else {
          if (!optional) expect('.');
          final name = peek;
          if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name))
            _unsupported();
          at++;
          key = _EvalExpr(() => name);
        }
        JCallSite site() {
          final object = previous.read();
          if (identical(object, jShortCircuit) ||
              optional && jNullish(object)) {
            return JCallSite(jShortCircuit);
          }
          return JCallSite.member(object, key.read());
        }

        JRef reference() {
          final object = previous.read();
          return JRef.member(object, key.read(), strict: strictFunction);
        }

        value = _EvalExpr(
          () => site().function,
          null,
          chain ? null : reference,
          site,
          null,
          false,
          () {
            final object = previous.read();
            if (identical(object, jShortCircuit) ||
                optional && jNullish(object))
              return true;
            return jDelete(object, key.read(), strict: strictFunction);
          },
        );
      } else {
        if (!chain) return value;
        final site = value.callSite;
        return _EvalExpr(
          () => jEndChain(previous.read()),
          null,
          null,
          site == null
              ? null
              : () {
                  final call = site();
                  return JCallSite(
                    jEndChain(call.function),
                    receiver: call.receiver,
                  );
                },
          null,
          false,
          previous.remove,
        );
      }
    }
  }

  List<(_EvalExpr?, bool)> expressionList(String end, {bool holes = false}) {
    final items = <(_EvalExpr?, bool)>[];
    while (!take(end)) {
      if (holes && take(',')) {
        items.add((null, false));
        continue;
      }
      final spread = take('...');
      items.add((expression(), spread));
      if (take(',')) {
        if (spread && !holes && peek == end) _unsupported();
      } else {
        expect(end);
        break;
      }
    }
    return items;
  }

  List<dynamic> evaluateList(List<(_EvalExpr?, bool)> items) => [
    for (final (item, spread) in items)
      if (item == null)
        _jHole
      else if (spread)
        ...jIterable(item.read())
      else
        item.read(),
  ];

  int closingToken(int start, String end) {
    final open = tokens[start];
    var depth = 1;
    for (var index = start + 1; index < tokens.length - 1; index++) {
      if (tokens[index] == open) depth++;
      if (tokens[index] == end && --depth == 0) return index;
    }
    _unsupported();
  }

  String groupSource(String open, String end) {
    final start = at;
    expect(open);
    final close = closingToken(start, end);
    at = close + 1;
    return source.substring(offsets[start] + open.length, offsets[close]);
  }

  String tokenSource(int start) =>
      source.substring(offsets[start], offsets[at - 1] + tokens[at - 1].length);

  bool startsArrow() {
    if (peek != '(' && !RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(peek))
      return false;
    final next = peek == '(' ? closingToken(at, ')') + 1 : at + 1;
    return !lineBreaks.contains(next) && tokens[next] == '=>';
  }

  _EvalExpr arrowFunction() {
    final start = at;
    final parameters = peek == '('
        ? groupSource('(', ')')
        : bindingIdentifier();
    expect('=>');
    final concise = peek != '{';
    late final String body;
    if (concise) {
      final bodyStart = at;
      expression();
      body = tokenSource(bodyStart);
    } else {
      body = groupSource('{', '}');
    }
    final code = _RuntimeFunctionCode(
      parameters,
      body,
      scope.current,
      arrow: true,
      concise: concise,
      inheritedStrict: strictFunction,
      lexicalTarget: newTarget,
      lexicalHome: home,
    );
    final lexicalScope = scope;
    final text = tokenSource(start);
    return _EvalExpr(
      () => code.create(
        lexicalScope.current,
        '',
        text,
        lexicalThis: thisValue,
        home: home,
      ),
      null,
      null,
      null,
      null,
      true,
    );
  }

  _EvalExpr functionLiteral(int start, String name, {bool bindName = false}) {
    final parameters = groupSource('(', ')');
    final body = groupSource('{', '}');
    final code = _RuntimeFunctionCode(
      parameters,
      body,
      scope.current,
      inheritedStrict: strictFunction,
    );
    final lexicalScope = scope;
    final text = tokenSource(start);
    return _EvalExpr(
      () {
        final outer = lexicalScope.current;
        final environment = bindName ? JScope(outer) : outer;
        final fn = code.create(environment, name, text);
        if (bindName) environment.define(name, fn, constant: true);
        return fn;
      },
      null,
      null,
      null,
      null,
      name.isEmpty,
    );
  }

  _EvalRead functionDeclaration() {
    final start = at;
    expect('function');
    final pattern = identifierPattern();
    final variable = lexicalEnvironments.length == 1;
    registerBinding(pattern, variable: variable);
    final name = pattern.names.single;
    final lexicalScope = scope;
    if (variable) functionNames.add(name);
    final definition = functionLiteral(start, name);
    hoisted.last.add(() {
      final fn = definition.read();
      if (variable) {
        variableScope.declareFunction(name, fn);
      } else {
        lexicalScope.current.define(name, fn);
      }
    });
    return () => _jRuntimeEmpty;
  }

  _EvalExpr objectLiteral() {
    final entries = <void Function(JObject)>[];
    var hasPrototype = false;
    while (!take('}')) {
      if (take('...')) {
        final source = expression();
        entries.add((object) {
          for (final entry in jObjectSpread(source.read())) {
            jApplyObjectEntry(object, entry);
          }
        });
      } else {
        final start = at;
        var kind = 'init';
        if ((peek == 'get' || peek == 'set') &&
            !const {':', ',', '}', '('}.contains(tokens[at + 1])) {
          kind = tokens[at++];
        }
        final computed = take('[');
        final token = peek;
        late final _EvalExpr key;
        if (computed) {
          key = sequence();
          expect(']');
        } else if (RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(token)) {
          at++;
          key = _EvalExpr(() => token);
        } else if (token.startsWith('"') ||
            token.startsWith("'") ||
            RegExp(r'^\d').hasMatch(token)) {
          key = atom();
        } else {
          _unsupported();
        }
        final lexicalScope = scope;
        if (peek == '(') {
          final parameters = groupSource('(', ')');
          final body = groupSource('{', '}');
          final code = _RuntimeFunctionCode(
            parameters,
            body,
            scope.current,
            method: true,
            inheritedStrict: strictFunction,
          );
          if ((kind == 'get' && code.parameterCount != 0) ||
              (kind == 'set' &&
                  (code.parameterCount != 1 || code.restParameter)))
            _unsupported();
          final text = tokenSource(start);
          entries.add((object) {
            final property = jPropertyKey(key.read());
            final name = jFunctionKeyName(property);
            final fn = code.create(
              lexicalScope.current,
              kind == 'init' ? name : '$kind $name',
              text,
              home: object,
            );
            jApplyObjectEntry(object, (kind, property, fn));
          });
        } else {
          if (kind != 'init') _unsupported();
          final hasValue = take(':');
          if (!hasValue &&
              (computed ||
                  !_runtimeBindingName(token) ||
                  !RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(token)))
            _unsupported();
          final value = hasValue
              ? expression()
              : _EvalExpr(
                  () => lexicalScope.current.get(token, strict: strictFunction),
                );
          final prototype = !computed && hasValue && key.read() == '__proto__';
          if (prototype && hasPrototype) _unsupported();
          hasPrototype |= prototype;
          entries.add((object) {
            final property = jPropertyKey(key.read());
            jApplyObjectEntry(object, (
              prototype ? 'prototype' : 'init',
              property,
              prototype ? value.read() : value.readNamed(property),
            ));
          });
        }
      }
      if (!take(',')) {
        expect('}');
        break;
      }
    }
    return _EvalExpr(() {
      final object = JObject();
      for (final entry in entries) entry(object);
      return object;
    });
  }

  _EvalExpr atom() {
    if (regexLiterals[at] case (final pattern, final flags)) {
      at++;
      JRegex(pattern, flags); // Validate the literal during parsing.
      return _EvalExpr(() => JRegex(pattern, flags));
    }
    final token = peek;
    if (token.isEmpty) _unsupported();
    if (take('function')) {
      final start = at - 1;
      final name = peek == '(' ? '' : bindingIdentifier();
      return functionLiteral(start, name, bindName: name.isNotEmpty);
    }
    if (take('(')) {
      final value = sequence();
      expect(')');
      return value;
    }
    if (take('[')) {
      final elements = expressionList(']', holes: true);
      return _EvalExpr(() => JArray(evaluateList(elements)));
    }
    if (take('{')) return objectLiteral();
    if (take('super')) {
      final owner = home;
      if (owner == null) _unsupported();
      late final _EvalExpr key;
      if (take('[')) {
        key = sequence();
        expect(']');
      } else {
        expect('.');
        final name = peek;
        if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name))
          _unsupported();
        at++;
        key = _EvalExpr(() => name);
      }
      JRef ref() => jSuperReference(thisValue, owner, key.read());
      return _EvalExpr(
        () => ref().read(),
        null,
        ref,
        () => jSuperCallSite(thisValue, owner, key.read()),
      );
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
            'function',
            'new',
          }.contains(peek) &&
          RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(peek) &&
          !const {'.', '[', '(', '?.'}.contains(tokens[at + 1])) {
        final name = tokens[at++];
        final lexicalScope = scope;
        return _EvalExpr(
          () => jUnary(
            'typeof',
            lexicalScope.current.getForTypeof(name, strict: strictFunction),
          ),
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
      () => lexicalScope.current.get(token, strict: strictFunction),
      (value) => lexicalScope.current.put(token, value, strict: strictFunction),
      () => JRef.scope(lexicalScope.current, token, strict: strictFunction),
      () => lexicalScope.current.callSite(token, strict: strictFunction),
      token,
      false,
      () => lexicalScope.current.deleteBinding(token),
    );
  }
}

dynamic jRuntimeEval(
  dynamic value,
  JScope scope,
  dynamic thisValue, {
  bool strict = false,
  dynamic newTarget = _noNewTarget,
  JObject? home,
}) {
  if (value is! String) return value;
  final parser = _RuntimeEvalParser(
    value,
    JScope(scope),
    thisValue,
    strictFunction: strict,
    newTarget: newTarget,
    home: home,
  );
  final statements = parser.parse();
  parser.variableScope.prepareEval(
    parser.strictFunction,
    parser.variableNames.toList(),
    parser.functionNames.toList(),
  );
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
  dynamic thisValue, {
  bool strict = false,
  dynamic newTarget = _noNewTarget,
  JObject? home,
  dynamic receiver = jUndefined,
}) => callee is JEvalFunction && identical(callee.realm, JRealm.current)
    ? jRuntimeEval(
        jArg(args, 0),
        scope,
        thisValue,
        strict: strict,
        newTarget: newTarget,
        home: home,
      )
    : jCall(callee, args, receiver: receiver);

class _RuntimeJump implements Exception {
  final bool isBreak;
  final String? label;
  dynamic value = _jRuntimeEmpty;
  _RuntimeJump(this.isBreak, this.label);

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
  return _RuntimeFunctionCode(parameters, body, root).create(
    root.scriptGlobalScope,
    'anonymous',
    'function anonymous($parameters\n) {\n$body\n}',
  );
}

class _RuntimeFunctionCode {
  final String parameters, body;
  final bool arrow, concise, method;
  final dynamic lexicalTarget;
  final JObject? lexicalHome;
  late final int parameterCount;
  late final bool restParameter;
  late final bool strict, simple;
  late final List<String> names;
  late final int length;
  _RuntimeFunctionCode(
    this.parameters,
    this.body,
    JScope scope, {
    this.arrow = false,
    this.concise = false,
    this.method = false,
    this.lexicalTarget = _noNewTarget,
    this.lexicalHome,
    bool inheritedStrict = false,
  }) {
    final validation = _RuntimeEvalParser(
      body,
      JScope(scope),
      jUndefined,
      functionBody: true,
      strictFunction: inheritedStrict,
      newTarget: arrow ? lexicalTarget : jUndefined,
      home: method ? jObjectPrototype : lexicalHome,
    );
    if (!concise) parseBody(validation);
    strict = validation.strictFunction;
    final signature = _RuntimeEvalParser(
      parameters,
      JScope(scope),
      jUndefined,
      strictFunction: strict,
      newTarget: arrow ? lexicalTarget : jUndefined,
      home: method ? jObjectPrototype : lexicalHome,
    ).parameters();
    parameterCount = signature.length;
    restParameter = signature.isNotEmpty && signature.last.$2;
    names = [for (final (pattern, _) in signature) ...pattern.names];
    simple = signature.every((entry) => entry.$1.simple && !entry.$2);
    length = signature
        .takeWhile((entry) => !entry.$1.hasDefault && !entry.$2)
        .length;
    if (names.any(validation.lexicalNames.contains) ||
        (!simple && validation.strictDirective) ||
        ((!simple || strict || arrow || method) &&
            names.toSet().length != names.length)) {
      throw JThrown(
        JError('SyntaxError', 'Invalid function parameter binding'),
      );
    }
  }

  List<_EvalRead> parseBody(_RuntimeEvalParser parser) {
    if (!concise) return parser.parse();
    final value = parser.expression();
    if (parser.peek.isNotEmpty) parser._unsupported();
    return [() => throw _RuntimeReturn(value.read())];
  }

  JFunction create(
    JScope outer,
    String name,
    String source, {
    dynamic lexicalThis,
    JObject? home,
  }) {
    late final JFunction function;
    dynamic invoke(List<dynamic> actual, dynamic receiver, dynamic target) {
      final parametersScope = JScope.function(outer);
      final newTarget = arrow ? lexicalTarget : target;
      final thisValue = arrow
          ? lexicalThis
          : strict
          ? receiver
          : jNullish(receiver)
          ? outer.globalThisValue
          : jObject(receiver);
      if (simple) {
        for (final name in names.toSet()) {
          parametersScope.define(name, jArg(actual, names.lastIndexOf(name)));
        }
      } else {
        for (final name in names) parametersScope.reserve(name);
      }
      if (!arrow && !names.contains('arguments')) {
        parametersScope.define(
          'arguments',
          jArgumentsObject(
            actual,
            environment: simple && !strict ? parametersScope : null,
            names: names,
            callee: function,
          ),
        );
      }
      final variables = simple
          ? parametersScope
          : JScope.function(parametersScope);
      final parser = _RuntimeEvalParser(
        body,
        JScope(variables),
        thisValue,
        functionBody: true,
        variables: variables,
        strictFunction: strict,
        newTarget: newTarget,
        home: home,
      );
      if (!simple) {
        final bindings = _RuntimeEvalParser(
          parameters,
          parametersScope,
          thisValue,
          strictFunction: strict,
          newTarget: newTarget,
          home: home,
        ).parameters();
        for (var index = 0; index < bindings.length; index++) {
          final (pattern, rest) = bindings[index];
          final value = rest
              ? actual.skip(index).toList()
              : jArg(actual, index);
          parser.initializeBinding(
            pattern,
            value,
            parametersScope,
            constant: false,
            variable: false,
          );
        }
      }
      final statements = parseBody(parser);
      if (!simple) {
        for (final name in parser.variableNames) {
          if (names.contains(name))
            variables.define(name, parametersScope.get(name));
        }
      }
      parser.instantiate();
      try {
        for (final statement in statements) statement();
      } on _RuntimeReturn catch (completion) {
        return completion.value;
      }
      return jUndefined;
    }

    function = arrow || method
        ? JFunction(
            (args, receiver) => invoke(args, receiver, jUndefined),
            constructible: false,
          )
        : jFunction(invoke);
    return jNamedFunction(function, name, length, source: source);
  }
}
