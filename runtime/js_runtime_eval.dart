part of 'js_core.dart';

// A deliberately small runtime parser. Parse the complete input before running
// any expression so unsupported syntax cannot cause partial side effects.
typedef _EvalRead = dynamic Function();

class _EvalExpr {
  final _EvalRead read;
  final dynamic Function(dynamic)? write;
  _EvalExpr(this.read, [this.write]);
}

class _RuntimeEvalParser {
  final String source;
  final JScope scope;
  final dynamic thisValue;
  final List<String> tokens = [];
  int at = 0;
  _RuntimeEvalParser(this.source, this.scope, this.thisValue) {
    final token = RegExp(
      r'''\s+|(?:[A-Za-z_$][A-Za-z0-9_$]*)|(?:\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)|(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?:===|!==|>>>|\*\*|==|!=|<=|>=|&&|\|\||\?\?|<<|>>|\+\+|--|\+=|-=|\*=|/=|=>)|[()+\-*/%<>=!~;]''',
    );
    var pos = 0;
    while (pos < source.length) {
      final match = token.matchAsPrefix(source, pos);
      if (match == null) _unsupported();
      final word = match.group(0)!;
      if (word.trim().isNotEmpty) tokens.add(word);
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
    '==': 3,
    '!=': 3,
    '===': 3,
    '!==': 3,
    '<': 4,
    '>': 4,
    '<=': 4,
    '>=': 4,
    '<<': 5,
    '>>': 5,
    '>>>': 5,
    '+': 6,
    '-': 6,
    '*': 7,
    '/': 7,
    '%': 7,
    '**': 8,
  };
  List<_EvalRead> parse() {
    final statements = <_EvalRead>[];
    while (peek.isNotEmpty) {
      if (take(';')) continue;
      statements.add(expression().read);
      if (peek.isNotEmpty) expect(';');
    }
    return statements;
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
    if (min == 0 && take('=')) {
      final target = left.write;
      if (target == null) _unsupported();
      final right = expression();
      left = _EvalExpr(() => target(right.read()));
    }
    return left;
  }

  _EvalExpr primary() {
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
          RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(peek)) {
        final name = tokens[at++];
        return _EvalExpr(() => jUnary('typeof', scope.getForTypeof(name)));
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
    return _EvalExpr(
      () => scope.get(token),
      (value) => scope.put(token, value),
    );
  }
}

dynamic jRuntimeEval(dynamic value, JScope scope, dynamic thisValue) {
  if (value is! String) return value;
  final statements = _RuntimeEvalParser(
    value,
    JScope(scope),
    thisValue,
  ).parse();
  dynamic result = jUndefined;
  for (final statement in statements) {
    result = statement();
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
