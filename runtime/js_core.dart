// HTGC JavaScript semantics implemented in Dart. No JavaScript engine or eval.
import 'dart:math' as math;

class JUndefined {
  const JUndefined();
}

const jUndefined = JUndefined();

class JShortCircuit {
  const JShortCircuit();
}

const jShortCircuit = JShortCircuit();
bool jNullish(dynamic value) => value == null || identical(value, jUndefined);
dynamic jEndChain(dynamic value) =>
    identical(value, jShortCircuit) ? jUndefined : value;
dynamic jArg(List<dynamic> args, int i) =>
    i < args.length ? args[i] : jUndefined;
dynamic jDefault(dynamic value, dynamic Function() fallback) =>
    identical(value, jUndefined) ? fallback() : value;

class JScope {
  final JScope? parent;
  final Map<String, dynamic> _values = {};
  final Set<String> _constants = {};
  JScope([this.parent]);
  dynamic define(String name, dynamic value, {bool constant = false}) {
    if (_values.containsKey(name))
      throw StateError('Identifier already declared: $name');
    _values[name] = value;
    if (constant) _constants.add(name);
    return value;
  }

  dynamic get(String name) {
    if (_values.containsKey(name)) return _values[name];
    if (parent != null) return parent!.get(name);
    if (name == 'undefined') return jUndefined;
    if (name == 'NaN') return double.nan;
    if (name == 'Infinity') return double.infinity;
    throw StateError('JavaScript ReferenceError: $name');
  }

  dynamic put(String name, dynamic value) {
    if (_values.containsKey(name)) {
      if (_constants.contains(name))
        throw StateError('Assignment to constant: $name');
      return _values[name] = value;
    }
    if (parent != null) return parent!.put(name, value);
    throw StateError('Assignment to undeclared name: $name');
  }
}

class JObject {
  final Map<String, dynamic> properties;
  JObject? prototype;
  JObject([Map<String, dynamic>? properties]) : properties = properties ?? {};
  dynamic get(String name) => properties.containsKey(name)
      ? properties[name]
      : prototype?.get(name) ?? jUndefined;
  dynamic set(String name, dynamic value) => properties[name] = value;
}

class JFunction extends JObject {
  final dynamic Function(List<dynamic>, dynamic) invoke;
  JFunction(this.invoke);
}

JFunction jNative(dynamic Function(List<dynamic>) callback) =>
    JFunction((args, receiver) => callback(args));

class JClass extends JObject {
  final dynamic base;
  final Map<String, dynamic> methods;
  JClass(this.base, this.methods);
  void attach(JObject instance) {
    if (base is JClass) (base as JClass).attach(instance);
    instance.properties.addAll(methods);
  }
}

class JRegex {
  final String pattern, flags;
  late final RegExp value = RegExp(pattern,
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
      unicode: flags.contains('u'));
  JRegex(this.pattern, this.flags);
}

class JRef {
  final dynamic Function() read;
  final dynamic Function(dynamic) write;
  JRef(this.read, this.write);
  factory JRef.scope(JScope scope, String key) =>
      JRef(() => scope.get(key), (v) => scope.put(key, v));
  factory JRef.member(dynamic object, dynamic key) =>
      JRef(() => jGet(object, key), (v) => jSet(object, key, v));
}

bool jTruthy(dynamic v) {
  if (jNullish(v) || identical(v, jShortCircuit)) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

String jString(dynamic v) {
  if (identical(v, jUndefined)) return 'undefined';
  if (v == null) return 'null';
  if (v is String) return v;
  if (v is List) return v.map((e) => jNullish(e) ? '' : jString(e)).join(',');
  if (v is JObject) return '[object Object]';
  if (v is double && v.isFinite && v == v.truncateToDouble())
    return v.toInt().toString();
  if (v is double && v.isNaN) return 'NaN';
  return v.toString();
}

num jNumber(dynamic v) {
  if (v == null) return 0;
  if (identical(v, jUndefined)) return double.nan;
  if (v is num) return v;
  if (v is bool) return v ? 1 : 0;
  final text = jString(v).trim();
  return text.isEmpty ? 0 : num.tryParse(text) ?? double.nan;
}

Iterable<dynamic> jIterable(dynamic value) {
  if (value is Iterable) return value.cast<dynamic>();
  if (value is String) return value.runes.map((r) => String.fromCharCode(r));
  throw StateError('Not iterable: ${jString(value)}');
}

Map<String, dynamic> jProperties(dynamic value) {
  if (value is JObject) return value.properties;
  if (value is List)
    return {for (var i = 0; i < value.length; i++) '$i': value[i]};
  if (jNullish(value)) return {};
  throw StateError('Object spread is unsupported for this value');
}

dynamic jCall(dynamic fn, List<dynamic> args,
    {dynamic receiver = jUndefined, bool optional = false}) {
  if (identical(fn, jShortCircuit)) return jShortCircuit;
  if (optional && jNullish(fn)) return jShortCircuit;
  if (fn is JFunction) return fn.invoke(args, receiver);
  throw StateError('Not callable: ${jString(fn)}');
}

dynamic jInvoke(dynamic object, dynamic key, List<dynamic> args,
        {bool optionalObject = false, bool optionalCall = false}) =>
    jCall(jGet(object, key, optional: optionalObject), args,
        receiver: object, optional: optionalCall);
dynamic jNew(dynamic constructor, List<dynamic> args) {
  if (constructor is JClass) {
    final result = constructor.base is JFunction
        ? jNew(constructor.base, args)
        : JObject();
    constructor.attach(result);
    return result;
  }
  if (constructor is JFunction) return jCall(constructor, args);
  throw StateError('Not a constructor');
}

dynamic jGet(dynamic value, dynamic key, {bool optional = false}) {
  if (identical(value, jShortCircuit)) return jShortCircuit;
  if (optional && jNullish(value)) return jShortCircuit;
  if (jNullish(value))
    throw StateError('Cannot read ${jString(key)} of ${jString(value)}');
  final name = jString(key);
  if (value is JObject) return value.get(name);
  if (value is List) {
    if (name == 'length') return value.length;
    final i = int.tryParse(name);
    if (i != null) return i >= 0 && i < value.length ? value[i] : jUndefined;
    switch (name) {
      case 'push':
        return jNative((a) {
          value.addAll(a);
          return value.length;
        });
      case 'pop':
        return jNative((a) => value.isEmpty ? jUndefined : value.removeLast());
      case 'join':
        return jNative((a) => value
            .map((x) => jNullish(x) ? '' : jString(x))
            .join(a.isEmpty ? ',' : jString(a[0])));
      case 'map':
        return jNative((a) => [
              for (var i = 0; i < value.length; i++)
                jCall(a[0], [value[i], i, value])
            ]);
      case 'filter':
        return jNative((a) => [
              for (var i = 0; i < value.length; i++)
                if (jTruthy(jCall(a[0], [value[i], i, value]))) value[i]
            ]);
      case 'forEach':
        return jNative((a) {
          for (var i = 0; i < value.length; i++)
            jCall(a[0], [value[i], i, value]);
          return jUndefined;
        });
      case 'some':
        return jNative((a) {
          for (var i = 0; i < value.length; i++) {
            if (jTruthy(jCall(a[0], [value[i], i, value]))) return true;
          }
          return false;
        });
      case 'every':
        return jNative((a) {
          for (var i = 0; i < value.length; i++) {
            if (!jTruthy(jCall(a[0], [value[i], i, value]))) return false;
          }
          return true;
        });
      case 'sort':
        return jNative((a) {
          final indexed = [
            for (var i = 0; i < value.length; i++) [value[i], i]
          ];
          indexed.sort((x, y) {
            final c = a.isEmpty
                ? jString(x[0]).compareTo(jString(y[0]))
                : jNumber(jCall(a[0], [x[0], y[0]])).sign.toInt();
            return c == 0 ? (x[1] as int).compareTo(y[1] as int) : c;
          });
          for (var i = 0; i < value.length; i++) {
            value[i] = indexed[i][0];
          }
          return value;
        });
      case 'includes':
        return jNative((a) => value.any((x) => jBinary('===', x, jArg(a, 0))));
      case 'indexOf':
        return jNative(
            (a) => value.indexWhere((x) => jBinary('===', x, jArg(a, 0))));
      case 'slice':
        return jNative((a) {
          int ix(dynamic v) {
            final n = jNumber(v).toInt();
            return (n < 0 ? value.length + n : n).clamp(0, value.length);
          }

          return value.sublist(
              a.isEmpty ? 0 : ix(a[0]), a.length < 2 ? value.length : ix(a[1]));
        });
    }
  }
  if (value is String) {
    if (name == 'length') return value.length;
    final i = int.tryParse(name);
    if (i != null) return i >= 0 && i < value.length ? value[i] : jUndefined;
    switch (name) {
      case 'trim':
        return jNative((a) => value.trim());
      case 'toLowerCase':
        return jNative((a) => value.toLowerCase());
      case 'toUpperCase':
        return jNative((a) => value.toUpperCase());
      case 'includes':
        return jNative((a) => value.contains(jString(a[0])));
      case 'startsWith':
        return jNative((a) => value.startsWith(jString(a[0])));
      case 'endsWith':
        return jNative((a) => value.endsWith(jString(a[0])));
      case 'split':
        return jNative((a) => a.isEmpty
            ? [value]
            : value.split(
                a[0] is JRegex ? (a[0] as JRegex).value : jString(a[0])));
      case 'match':
        return jNative((a) {
          final re =
              a[0] is JRegex ? a[0] as JRegex : JRegex(jString(a[0]), '');
          if (re.flags.contains('g')) {
            final matches =
                re.value.allMatches(value).map((m) => m[0]).toList();
            return matches.isEmpty ? null : matches;
          }
          final m = re.value.firstMatch(value);
          return m == null
              ? null
              : [for (var i = 0; i <= m.groupCount; i++) m[i] ?? jUndefined];
        });
      case 'replace':
        return jNative((a) {
          final re = a[0] is JRegex ? a[0] as JRegex : null;
          final Pattern pattern = re?.value ?? jString(a[0]);
          String replacement(Match m) {
            if (a[1] is JFunction)
              return jString(jCall(a[1], [
                m[0],
                for (var i = 1; i <= m.groupCount; i++) m[i],
                m.start,
                value
              ]));
            return jString(a[1])
                .replaceAllMapped(RegExp(r'\$(\$|&|[0-9]{1,2})'), (p) {
              if (p[1] == '\$') return '\$';
              if (p[1] == '&') return m[0]!;
              final index = int.parse(p[1]!);
              return index > 0 && index <= m.groupCount
                  ? m[index] ?? ''
                  : p[0]!;
            });
          }

          return re?.flags.contains('g') == true
              ? value.replaceAllMapped(pattern, replacement)
              : value.replaceFirstMapped(pattern, replacement);
        });
    }
  }
  if (value is JRegex && name == 'test')
    return jNative((a) => value.value.hasMatch(jString(a[0])));
  if (value is num && name == 'toString') return jNative((a) => jString(value));
  return jUndefined;
}

dynamic jSet(dynamic value, dynamic key, dynamic assigned) {
  final name = jString(key);
  if (value is JObject) return value.set(name, assigned);
  if (value is List) {
    if (name == 'length') {
      final size = jNumber(assigned).toInt();
      while (value.length < size) {
        value.add(jUndefined);
      }
      value.length = size;
      return assigned;
    }
    final i = int.tryParse(name);
    if (i != null && i >= 0) {
      while (value.length <= i) {
        value.add(jUndefined);
      }
      value[i] = assigned;
      return assigned;
    }
  }
  throw StateError('Cannot assign property $name');
}

dynamic jAssign(JRef ref, String op, dynamic Function() rhs) {
  if (op == '=') return ref.write(rhs());
  final left = ref.read();
  if (op == '||=' && jTruthy(left) ||
      op == '&&=' && !jTruthy(left) ||
      op == '??=' && !jNullish(left)) return left;
  return ref.write(['||=', '&&=', '??='].contains(op)
      ? rhs()
      : jBinary(op.substring(0, op.length - 1), left, rhs()));
}

dynamic jUpdate(JRef ref, num delta, bool prefix) {
  final old = jNumber(ref.read());
  final next = old + delta;
  ref.write(next);
  return prefix ? next : old;
}

dynamic jLogical(String op, dynamic left, dynamic Function() right) {
  if (op == '&&') return jTruthy(left) ? right() : left;
  if (op == '||') return jTruthy(left) ? left : right();
  if (op == '??') return jNullish(left) ? right() : left;
  throw StateError('Logical operator $op');
}

dynamic jUnary(String op, dynamic value) {
  switch (op) {
    case '!':
      return !jTruthy(value);
    case '-':
      return -jNumber(value);
    case '+':
      return jNumber(value);
    case '~':
      return ~jNumber(value).toInt();
    case 'void':
      return jUndefined;
    case 'typeof':
      return identical(value, jUndefined)
          ? 'undefined'
          : value is bool
              ? 'boolean'
              : value is num
                  ? 'number'
                  : value is String
                      ? 'string'
                      : value is JFunction
                          ? 'function'
                          : 'object';
  }
  throw StateError('Unary operator $op');
}

dynamic jBinary(String op, dynamic a, dynamic b) {
  switch (op) {
    case '===':
      return a is num && b is num
          ? a == b
          : a.runtimeType == b.runtimeType && a == b;
    case '!==':
      return !jBinary('===', a, b);
    case '==':
      return jNullish(a) && jNullish(b) ||
          jBinary('===', a, b) ||
          ((a is num || a is bool || b is num || b is bool) &&
              jNumber(a) == jNumber(b));
    case '!=':
      return !jBinary('==', a, b);
    case '+':
      return a is String || b is String
          ? jString(a) + jString(b)
          : jNumber(a) + jNumber(b);
    case '-':
      return jNumber(a) - jNumber(b);
    case '*':
      return jNumber(a) * jNumber(b);
    case '/':
      return jNumber(a) / jNumber(b);
    case '%':
      return jNumber(a).remainder(jNumber(b));
    case '**':
      return math.pow(jNumber(a), jNumber(b));
    case '<':
      return a is String && b is String
          ? a.compareTo(b) < 0
          : jNumber(a) < jNumber(b);
    case '>':
      return a is String && b is String
          ? a.compareTo(b) > 0
          : jNumber(a) > jNumber(b);
    case '<=':
      return a is String && b is String
          ? a.compareTo(b) <= 0
          : jNumber(a) <= jNumber(b);
    case '>=':
      return a is String && b is String
          ? a.compareTo(b) >= 0
          : jNumber(a) >= jNumber(b);
    case '&':
      return jNumber(a).toInt() & jNumber(b).toInt();
    case '|':
      return jNumber(a).toInt() | jNumber(b).toInt();
    case '^':
      return jNumber(a).toInt() ^ jNumber(b).toInt();
    case '<<':
      return jNumber(a).toInt() << jNumber(b).toInt();
    case '>>':
      return jNumber(a).toInt() >> jNumber(b).toInt();
    case 'in':
      return b is JObject && b.properties.containsKey(jString(a));
  }
  throw StateError('Binary operator $op');
}

void installJSBuiltins(JScope scope) {
  scope.define('Boolean', jNative((a) => jTruthy(jArg(a, 0))));
  scope.define('String', jNative((a) => a.isEmpty ? '' : jString(a[0])));
  scope.define('Number', jNative((a) => a.isEmpty ? 0 : jNumber(a[0])));
  scope.define('Date', jNative((a) {
    final now = DateTime.now();
    return JObject({'getFullYear': jNative((a) => now.year)});
  }));
  scope.define(
      'Array',
      JObject({
        'from': jNative((a) {
          final input = a[0];
          final list = input is Iterable || input is String
              ? jIterable(input).toList()
              : List<dynamic>.filled(
                  jNumber(jGet(input, 'length')).toInt(), jUndefined);
          return a.length < 2
              ? list
              : [
                  for (var i = 0; i < list.length; i++)
                    jCall(a[1], [list[i], i])
                ];
        })
      }));
  final random = math.Random();
  scope.define(
      'Math',
      JObject({
        'PI': math.pi,
        'random': jNative((a) => random.nextDouble()),
        'floor': jNative((a) => jNumber(a[0]).floor()),
        'ceil': jNative((a) => jNumber(a[0]).ceil()),
        'abs': jNative((a) => jNumber(a[0]).abs()),
        'sqrt': jNative((a) => math.sqrt(jNumber(a[0]))),
        'min':
            jNative((a) => a.map(jNumber).fold<num>(double.infinity, math.min)),
        'max': jNative(
            (a) => a.map(jNumber).fold<num>(double.negativeInfinity, math.max)),
        'hypot': jNative((a) =>
            math.sqrt(a.map(jNumber).fold<num>(0, (sum, v) => sum + v * v))),
      }));
  scope.define(
      'console',
      JObject({
        'log': jNative((a) {
          print(a.map(jString).join(' '));
          return jUndefined;
        })
      }));
}
